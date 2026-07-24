# Image Diffs Across All Panes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Render exact, lazy, retryable image comparisons in every Alas diff surface, while keeping GG Split Commit to a resulting-image preview and preserving the conflict-resolution UI.

**Architecture:** Extend the existing image pair model so each side can be loaded, missing, or failed, then introduce a deterministic `DiffReviewImageProvider` that resolves pairs only when a review file section is visible. Refactor the existing standalone image viewer into shared controls and comparison content, adapt every local and hosted diff source to the provider, and keep source-specific revision semantics behind Git or code-host adapters.

**Tech Stack:** Swift 5.9, SwiftUI and AppKit on macOS 15, Swift Observation, Swift Testing, Git CLI, GitHub `gh`, GitLab `glab`, XcodeGen.

## Global Constraints

- Keep code, comments, logs, and UI strings in English.
- Use Swift Testing (`import Testing`), not XCTest.
- Keep `SWIFT_STRICT_CONCURRENCY` at `complete`; do not silence isolation errors with broad `@unchecked Sendable`.
- Add no dependency and do not change the macOS 15 deployment target.
- Use the existing `ImageFileType.supportedExtensions`, Git LFS resolver, and four image comparison modes.
- Load exact immutable revisions for commit, range, stash, GitHub, and GitLab comparisons; never substitute a moving branch silently.
- Image sections support existing file-level feedback only; do not add line or coordinate anchors.
- GG Split Commit keeps images remainder-only and shows only the resulting image.
- Merge conflict resolution keeps the existing LOCAL/ours and REMOTE/theirs UI.
- Prefix every shell command with `rtk`.
- Run Xcode actions serially in this worktree.
- Run `xcodegen` whenever a task creates a Swift file, and commit the generated `Alas.xcodeproj/project.pbxproj` with that task.
- If a fresh-worktree build fails before compiling Alas because vendored modules are absent, initialize `ThirdParty/zmx` and `ThirdParty/fff` before interpreting the failure.
- Do not add agent attribution to code, commits, or pull-request text.

---

## File Structure

### New production files

- `Alas/Sources/Center/ImageDiff/ImageDiffPresentation.swift`
  - Owns reusable mode controls, reset controls, and comparison content.
- `Alas/Sources/Center/ImageDiff/ImageDiffDecodedCache.swift`
  - Cost-bounded cache and in-flight coalescing for immutable decoded images.
- `Alas/Sources/Center/DiffReview/DiffReviewImageProvider.swift`
  - Deterministic provider identity and lazy pair-loading closure.
- `Alas/Sources/Center/DiffReview/DiffReviewImageState.swift`
  - Main-actor load, cancellation, stale-result rejection, retry, and presentation state for one review file.

### New test files

- `AlasTests/ImageDiffDecodedCacheTests.swift`
- `AlasTests/DiffReviewImageStateTests.swift`

### Existing files with focused responsibility changes

- Image pair and renderer:
  - `Alas/Sources/Center/ImageDiff/ImageDiffPair.swift`
  - `Alas/Sources/Center/ImageDiff/ImageDiffPairKind.swift`
  - `Alas/Sources/Center/ImageDiff/ImageDiffPairResolver.swift`
  - `Alas/Sources/Center/ImageDiff/ImageDiffMode.swift`
  - `Alas/Sources/Center/ImageDiff/ImageDiffView.swift`
  - `Alas/Sources/Center/ImageDiff/GitService+ImageDiff.swift`
- Review model and shared surface:
  - `Alas/Sources/Center/DiffReview/DiffReviewModels.swift`
  - `Alas/Sources/Center/DiffReview/DiffReviewFileSection.swift`
- Local review sources:
  - `Alas/Sources/Center/ReviewChanges/ReviewChangesLoader.swift`
  - `Alas/Sources/Center/Commit/StagedDiffLoader.swift`
  - `Alas/Sources/Center/Commit/CommitReviewLoader.swift`
  - `Alas/Sources/Center/ReviewWorkspace/RangeReviewLoader.swift`
  - `Alas/Sources/Center/ReviewRequest/DraftReviewRequestDiffSessionBuilder.swift`
  - `Alas/Sources/Center/ReviewRequest/DraftReviewRequestTabView.swift`
  - `Alas/Sources/Center/ReviewWorkspace/ReviewSessionLoader.swift`
- Stashes:
  - `Alas/Sources/Git/GitService+Stash.swift`
  - `Alas/Sources/Center/StashDiffTabView.swift`
- Hosted reviews:
  - `Alas/Sources/Integrations/CodeHost/CodeHostModels.swift`
  - `Alas/Sources/Integrations/CodeHost/CodeHostProvider.swift`
  - `Alas/Sources/Integrations/CodeHost/GitHubCLIProvider.swift`
  - `Alas/Sources/Integrations/CodeHost/GitLabCLIProvider.swift`
  - `Alas/Sources/Integrations/CodeHost/ReviewRequestDiffLoader.swift`
- GG:
  - `Alas/Sources/Integrations/GG/GGSplitCommitTabView.swift`
  - `Alas/Sources/Center/CenterPaneView.swift`

---

### Task 1: Represent copy changes and per-side image outcomes

**Files:**
- Modify: `Alas/Sources/Center/ImageDiff/ImageDiffPair.swift:1-13`
- Modify: `Alas/Sources/Center/ImageDiff/ImageDiffPairKind.swift:1-8`
- Modify: `Alas/Sources/Center/ImageDiff/ImageDiffPairResolver.swift:1-92`
- Modify: `Alas/Sources/Center/ImageDiff/ImageDiffMode.swift:1-41`
- Modify: `Alas/Sources/Center/ImageDiff/ImageDiffView.swift:1-182`
- Modify: `AlasTests/ImageDiffPairResolverTests.swift`
- Modify: `AlasTests/ImageDiffModeApplicabilityTests.swift`
- Modify: `AlasTests/ImageDiffViewTests.swift`

**Interfaces:**
- Produces: `ImageDiffSide`, `ImageDiffLoadFailure`, `ImageDiffPairKind.copied`, `ImageDiffPair.beforeImage`, `ImageDiffPair.afterImage`, and `ImageDiffMode.isApplicable(for pair:)`.
- Consumes: Existing `NSImage`, `ImageDiffPair`, `CommitChangedFile`, and `ChangedFile`.

- [ ] **Step 1: Write failing copy and side-state tests**

Add these tests:

```swift
@Test func resolvesCommitFileCopied() {
    let file = CommitChangedFile(
        path: "Assets/Copy.png",
        originalPath: "Assets/Original.png",
        status: "C",
        add: 0,
        del: 0
    )

    let result = ImageDiffPairResolver.resolveCommit(entry: file)

    #expect(result.kind == .copied)
    #expect(result.oldPath == "Assets/Original.png")
}

@Test func nonSideBySideModesRequireTwoLoadedImages() {
    let pair = ImageDiffPair(
        before: .failed(ImageDiffLoadFailure(message: "Before failed")),
        after: .image(NSImage(size: NSSize(width: 1, height: 1)), frameCount: 1),
        oldPath: nil,
        kind: .modified
    )

    #expect(ImageDiffMode.sideBySide.isApplicable(for: pair))
    #expect(!ImageDiffMode.overlay.isApplicable(for: pair))
    #expect(!ImageDiffMode.swipe.isApplicable(for: pair))
    #expect(!ImageDiffMode.difference.isApplicable(for: pair))
}

@Test func copiedPairSupportsEveryModeWhenBothSidesLoad() {
    let image = NSImage(size: NSSize(width: 1, height: 1))
    let pair = ImageDiffPair(
        before: .image(image, frameCount: 1),
        after: .image(image, frameCount: 1),
        oldPath: "Assets/Original.png",
        kind: .copied
    )

    for mode in ImageDiffMode.allCases {
        #expect(mode.isApplicable(for: pair))
    }
}
```

- [ ] **Step 2: Run the focused tests and confirm the red state**

Run:

```bash
ALAS_FFF_TARGET_ARCH=arm64 rtk xcodebuild \
  -project Alas.xcodeproj \
  -scheme Alas \
  -destination 'platform=macOS' \
  -only-testing:AlasTests/ImageDiffPairResolverTests \
  -only-testing:AlasTests/ImageDiffModeApplicabilityTests \
  -only-testing:AlasTests/ImageDiffViewTests \
  test
```

Expected: FAIL because `.copied`, `ImageDiffSide`, and `isApplicable(for:)` do not exist.

- [ ] **Step 3: Add the pair-side and copy model**

Replace the pair representation with:

```swift
import AppKit

struct ImageDiffLoadFailure: Equatable, Sendable {
    let message: String
}

enum ImageDiffSide {
    case image(NSImage, frameCount: Int)
    case missing
    case failed(ImageDiffLoadFailure)

    var image: NSImage? {
        guard case .image(let image, _) = self else { return nil }
        return image
    }

    var frameCount: Int {
        guard case .image(_, let frameCount) = self else { return 0 }
        return frameCount
    }

    var isLoadedImage: Bool {
        image != nil
    }
}

struct ImageDiffPair {
    let before: ImageDiffSide
    let after: ImageDiffSide
    let oldPath: String?
    let kind: ImageDiffPairKind

    var beforeImage: NSImage? { before.image }
    var afterImage: NSImage? { after.image }
    var beforeFrameCount: Int { before.frameCount }
    var afterFrameCount: Int { after.frameCount }

    init(
        before: ImageDiffSide,
        after: ImageDiffSide,
        oldPath: String?,
        kind: ImageDiffPairKind
    ) {
        self.before = before
        self.after = after
        self.oldPath = oldPath
        self.kind = kind
    }

    init(
        before: NSImage?,
        after: NSImage?,
        oldPath: String?,
        kind: ImageDiffPairKind,
        beforeFrameCount: Int,
        afterFrameCount: Int
    ) {
        self.init(
            before: before.map { .image($0, frameCount: beforeFrameCount) } ?? .missing,
            after: after.map { .image($0, frameCount: afterFrameCount) } ?? .missing,
            oldPath: oldPath,
            kind: kind
        )
    }
}
```

Add `.copied` to `ImageDiffPairKind`. Map commit status `C` to `.copied`, keep `R` mapped to `.renamed`, and update all exhaustive switches.

Change mode applicability to:

```swift
func isApplicable(for pair: ImageDiffPair) -> Bool {
    switch self {
    case .sideBySide:
        return true
    case .overlay, .swipe, .difference:
        return pair.before.isLoadedImage && pair.after.isLoadedImage
    }
}
```

Update `ImageDiffView` to read `beforeImage` and `afterImage`, label copied changes as `COPIED old → new`, and make `snapToApplicableMode` accept an `ImageDiffPair`.

- [ ] **Step 4: Run focused tests**

Run the Step 2 command.

Expected: PASS for all three suites.

- [ ] **Step 5: Commit**

```bash
rtk git add \
  Alas/Sources/Center/ImageDiff/ImageDiffPair.swift \
  Alas/Sources/Center/ImageDiff/ImageDiffPairKind.swift \
  Alas/Sources/Center/ImageDiff/ImageDiffPairResolver.swift \
  Alas/Sources/Center/ImageDiff/ImageDiffMode.swift \
  Alas/Sources/Center/ImageDiff/ImageDiffView.swift \
  AlasTests/ImageDiffPairResolverTests.swift \
  AlasTests/ImageDiffModeApplicabilityTests.swift \
  AlasTests/ImageDiffViewTests.swift
rtk git commit -m "refactor(diff): model image side outcomes"
```

---

### Task 2: Add deterministic lazy providers and decoded-image caching

**Files:**
- Create: `Alas/Sources/Center/DiffReview/DiffReviewImageProvider.swift`
- Create: `Alas/Sources/Center/ImageDiff/ImageDiffDecodedCache.swift`
- Create: `AlasTests/ImageDiffDecodedCacheTests.swift`
- Modify: `Alas.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `ImageDiffPair`, `ImageDiffSide`, `NSImage`.
- Produces: `DiffReviewImageProviderID`, `DiffReviewImageProvider`, `ImageDiffDecodedCache.Key`, and `ImageDiffDecodedCache.image(for:cost:load:)`.

- [ ] **Step 1: Write failing provider-identity and cache tests**

Create `AlasTests/ImageDiffDecodedCacheTests.swift`:

```swift
import AppKit
import Testing
@testable import Alas

@MainActor
struct ImageDiffDecodedCacheTests {
    @Test func identicalImmutableKeysCoalesceConcurrentLoads() async {
        let cache = ImageDiffDecodedCache(totalCostLimit: 1_024_000)
        let key = ImageDiffDecodedCache.Key(
            repository: "/repo",
            revision: "abc123",
            path: "Assets/logo.png"
        )
        let calls = LockedCounter()

        async let first = cache.image(for: key, cost: 4) {
            calls.increment()
            return NSImage(size: NSSize(width: 1, height: 1))
        }
        async let second = cache.image(for: key, cost: 4) {
            calls.increment()
            return NSImage(size: NSSize(width: 1, height: 1))
        }

        #expect(await first != nil)
        #expect(await second != nil)
        #expect(calls.value == 1)
    }

    @Test func providerIdentityIncludesBothRevisionsAndPaths() {
        let lhs = DiffReviewImageProviderID(
            source: .range,
            repository: "/repo",
            beforeRevision: "base-a",
            afterRevision: "head",
            beforePath: "Assets/old.png",
            afterPath: "Assets/new.png"
        )
        let rhs = DiffReviewImageProviderID(
            source: .range,
            repository: "/repo",
            beforeRevision: "base-b",
            afterRevision: "head",
            beforePath: "Assets/old.png",
            afterPath: "Assets/new.png"
        )

        #expect(lhs != rhs)
    }

    @Test func cacheUsesTheConfiguredDecodedPixelBudget() {
        let cache = ImageDiffDecodedCache(totalCostLimit: 4096)
        #expect(cache.totalCostLimit == 4096)
    }
}
```

Define this test-local helper in the same file:

```swift
private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.withLock { storage }
    }

    func increment() {
        lock.withLock { storage += 1 }
    }
}
```

- [ ] **Step 2: Regenerate and verify the tests fail**

```bash
rtk xcodegen
ALAS_FFF_TARGET_ARCH=arm64 rtk xcodebuild \
  -project Alas.xcodeproj \
  -scheme Alas \
  -destination 'platform=macOS' \
  -only-testing:AlasTests/ImageDiffDecodedCacheTests \
  test
```

Expected: FAIL because the provider and cache types do not exist.

- [ ] **Step 3: Implement provider identity and cache**

Create `DiffReviewImageProvider.swift`:

```swift
import Foundation

struct DiffReviewImageProviderID: Hashable, Sendable {
    enum Source: String, Hashable, Sendable {
        case workingCopy
        case commit
        case range
        case stash
        case hostedReview
    }

    let source: Source
    let repository: String
    let beforeRevision: String
    let afterRevision: String
    let beforePath: String?
    let afterPath: String
}

struct DiffReviewImageProvider {
    let id: DiffReviewImageProviderID
    let load: @MainActor () async -> ImageDiffPair
}
```

Create `ImageDiffDecodedCache.swift` as a `@MainActor final class` with:

```swift
struct Key: Hashable, Sendable {
    let repository: String
    let revision: String
    let path: String
}
```

Expose `static let shared = ImageDiffDecodedCache(totalCostLimit: 256 * 1024 * 1024)` and `let totalCostLimit: Int`. Back the cache with `NSCache<NSString, Box>`, default `totalCostLimit` to `256 * 1024 * 1024`, and keep `[Key: Task<NSImage?, Never>]` for in-flight coalescing. Remove an in-flight entry in `defer`, store successful images with the supplied decoded cost (`pixelsWide * pixelsHigh * 4`), and never cache failures.

- [ ] **Step 4: Run focused tests**

Run the Step 2 `xcodebuild` command.

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
rtk git add \
  Alas/Sources/Center/DiffReview/DiffReviewImageProvider.swift \
  Alas/Sources/Center/ImageDiff/ImageDiffDecodedCache.swift \
  AlasTests/ImageDiffDecodedCacheTests.swift \
  Alas.xcodeproj/project.pbxproj
rtk git commit -m "feat(diff): add lazy image providers"
```

---

### Task 3: Extract reusable image controls and comparison content

**Files:**
- Create: `Alas/Sources/Center/ImageDiff/ImageDiffPresentation.swift`
- Modify: `Alas/Sources/Center/ImageDiff/ImageDiffView.swift`
- Modify: `Alas/Sources/Center/ImageDiff/ImageDiffSideBySideView.swift`
- Modify: `AlasTests/ImageDiffViewTests.swift`
- Modify: `AlasTests/ImageDiffSideBySideViewTests.swift`
- Modify: `Alas.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `ImageDiffPair`, `ImageDiffMode`, `ImageDiffTransform`.
- Produces: `ImageDiffPresentationState`, `ImageDiffControls`, and `ImageDiffComparisonContent`.

- [ ] **Step 1: Write failing presentation-state tests**

Add:

```swift
@MainActor
@Test func presentationResetsWhenPairChanges() {
    let state = ImageDiffPresentationState()
    state.mode = .difference
    state.transform = ImageDiffTransform(
        scale: 2,
        offset: CGSize(width: 20, height: 10)
    )
    state.percentChanged = 42

    state.resetForNewPair()

    #expect(state.mode == .sideBySide)
    #expect(state.transform == ImageDiffTransform())
    #expect(state.percentChanged == nil)
}

@MainActor
@Test func presentationSnapsAwayFromUnavailableMode() {
    let state = ImageDiffPresentationState()
    state.mode = .overlay
    let pair = ImageDiffPair(
        before: .missing,
        after: .image(NSImage(size: NSSize(width: 1, height: 1)), frameCount: 1),
        oldPath: nil,
        kind: .added
    )

    state.snapToApplicableMode(for: pair)

    #expect(state.mode == .sideBySide)
}
```

- [ ] **Step 2: Run the focused view tests**

```bash
ALAS_FFF_TARGET_ARCH=arm64 rtk xcodebuild \
  -project Alas.xcodeproj \
  -scheme Alas \
  -destination 'platform=macOS' \
  -only-testing:AlasTests/ImageDiffViewTests \
  -only-testing:AlasTests/ImageDiffSideBySideViewTests \
  test
```

Expected: FAIL because `ImageDiffPresentationState` does not exist.

- [ ] **Step 3: Extract presentation state, controls, and content**

Create an `@Observable @MainActor final class ImageDiffPresentationState`:

```swift
@Observable
@MainActor
final class ImageDiffPresentationState {
    var mode: ImageDiffMode = .sideBySide
    var percentChanged: Double?
    var transform = ImageDiffTransform()

    func resetForNewPair() {
        mode = .sideBySide
        percentChanged = nil
        transform = ImageDiffTransform()
    }

    func snapToApplicableMode(for pair: ImageDiffPair) {
        if !mode.isApplicable(for: pair) {
            mode = .sideBySide
        }
    }
}
```

Move the existing mode buttons, reset button, frame notice, comparison switch, and difference percentage into:

```swift
struct ImageDiffControls: View {
    let pair: ImageDiffPair
    @Bindable var state: ImageDiffPresentationState
}

struct ImageDiffComparisonContent: View {
    let pair: ImageDiffPair
    @Bindable var state: ImageDiffPresentationState
    var boundedHeight: CGFloat? = nil
}
```

`ImageDiffComparisonContent` uses `pair.beforeImage` and `pair.afterImage`. Change `ImageDiffSideBySideView` to accept `ImageDiffSide` values, preserving the existing missing-side placeholder and rendering `.failed` with the failure message in that side's column. When `boundedHeight` is non-nil, apply `.frame(height: boundedHeight)`.

Refactor `ImageDiffView` to own `@State private var presentation = ImageDiffPresentationState()` and compose the new controls/content while preserving the current standalone header.

- [ ] **Step 4: Regenerate and run focused tests**

```bash
rtk xcodegen
ALAS_FFF_TARGET_ARCH=arm64 rtk xcodebuild \
  -project Alas.xcodeproj \
  -scheme Alas \
  -destination 'platform=macOS' \
  -only-testing:AlasTests/ImageDiffViewTests \
  -only-testing:AlasTests/ImageDiffSideBySideViewTests \
  test
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
rtk git add \
  Alas/Sources/Center/ImageDiff/ImageDiffPresentation.swift \
  Alas/Sources/Center/ImageDiff/ImageDiffView.swift \
  Alas/Sources/Center/ImageDiff/ImageDiffSideBySideView.swift \
  AlasTests/ImageDiffViewTests.swift \
  AlasTests/ImageDiffSideBySideViewTests.swift \
  Alas.xcodeproj/project.pbxproj
rtk git commit -m "refactor(diff): share image comparison presentation"
```

---

### Task 4: Render lazy images in the shared review file section

**Files:**
- Create: `Alas/Sources/Center/DiffReview/DiffReviewImageState.swift`
- Create: `AlasTests/DiffReviewImageStateTests.swift`
- Modify: `Alas/Sources/Center/DiffReview/DiffReviewModels.swift:185-334`
- Modify: `Alas/Sources/Center/DiffReview/DiffReviewFileSection.swift:78-630`
- Modify: `AlasTests/DiffReviewRenderableContentEqualityTests.swift`
- Modify: `AlasTests/DiffReviewSurfaceTests.swift`
- Modify: `Alas.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `DiffReviewImageProvider`, `ImageDiffPresentationState`, `ImageDiffControls`, `ImageDiffComparisonContent`.
- Produces: `DiffReviewImageState.load(provider:)`, `retry()`, and review-file image rendering at a 360-point comparison height.

- [ ] **Step 1: Write failing lifecycle and equality tests**

Create `DiffReviewImageStateTests.swift` with a controlled continuation:

```swift
import AppKit
import Testing
@testable import Alas

@MainActor
struct DiffReviewImageStateTests {
    @Test func lateResultFromOldProviderIsRejected() async {
        let gate = PairLoadGate()
        let state = DiffReviewImageState()
        let old = provider(revision: "old") { await gate.wait() }
        let newPair = pair(color: .systemGreen)
        let new = provider(revision: "new") { newPair }

        let oldTask = Task { await state.load(provider: old) }
        await Task.yield()
        await state.load(provider: new)
        gate.resume(returning: pair(color: .systemRed))
        await oldTask.value

        #expect(state.providerID == new.id)
        #expect(state.pair?.afterImage === newPair.afterImage)
    }

    @Test func retryIncrementsOnlyTheCurrentSectionGeneration() async {
        let state = DiffReviewImageState()
        let provider = provider(revision: "head") {
            ImageDiffPair(
                before: .failed(.init(message: "Network error")),
                after: .missing,
                oldPath: nil,
                kind: .deleted
            )
        }

        await state.load(provider: provider)
        let firstGeneration = state.retryGeneration
        await state.retry()

        #expect(state.retryGeneration == firstGeneration + 1)
    }
}

@MainActor
private final class PairLoadGate {
    private var continuation: CheckedContinuation<ImageDiffPair, Never>?

    func wait() async -> ImageDiffPair {
        await withCheckedContinuation { continuation = $0 }
    }

    func resume(returning pair: ImageDiffPair) {
        continuation?.resume(returning: pair)
        continuation = nil
    }
}

@MainActor
private func provider(
    revision: String,
    load: @escaping @MainActor () async -> ImageDiffPair
) -> DiffReviewImageProvider {
    DiffReviewImageProvider(
        id: DiffReviewImageProviderID(
            source: .commit,
            repository: "/repo",
            beforeRevision: "\(revision)^",
            afterRevision: revision,
            beforePath: "Assets/logo.png",
            afterPath: "Assets/logo.png"
        ),
        load: load
    )
}

@MainActor
private func pair(color: NSColor) -> ImageDiffPair {
    let image = NSImage(size: NSSize(width: 1, height: 1))
    image.lockFocus()
    color.setFill()
    NSRect(x: 0, y: 0, width: 1, height: 1).fill()
    image.unlockFocus()
    return ImageDiffPair(
        before: .missing,
        after: .image(image, frameCount: 1),
        oldPath: nil,
        kind: .added
    )
}
```

Add equality tests proving identical provider IDs compare equal and a changed revision compares unequal.

- [ ] **Step 2: Regenerate and verify the red state**

```bash
rtk xcodegen
ALAS_FFF_TARGET_ARCH=arm64 rtk xcodebuild \
  -project Alas.xcodeproj \
  -scheme Alas \
  -destination 'platform=macOS' \
  -only-testing:AlasTests/DiffReviewImageStateTests \
  -only-testing:AlasTests/DiffReviewRenderableContentEqualityTests \
  test
```

Expected: FAIL because the state and model property do not exist.

- [ ] **Step 3: Implement state and model integration**

Add this model property with a default so existing memberwise initializer call sites continue compiling:

```swift
var imageProvider: DiffReviewImageProvider? = nil
```

Include `imageProvider?.id` in `hasSameRenderableContent(as:)`.

Create `DiffReviewImageState` as `@Observable @MainActor final class` with:

```swift
private(set) var providerID: DiffReviewImageProviderID?
private(set) var pair: ImageDiffPair?
private(set) var isLoading = false
private(set) var retryGeneration = 0
let presentation = ImageDiffPresentationState()
```

Retain the current provider for retry. `load(provider:)` resets state when the ID changes, captures the ID, awaits the closure, checks `Task.isCancelled` and the captured ID, then applies the pair. `retry()` increments the generation and invokes the retained provider again.

In `DiffReviewFileSection`:

- Add `@State private var imageState = DiffReviewImageState()`.
- Put `ImageDiffControls` and reset in the existing file header when a pair exists.
- Render existing file-level feedback before image content.
- Branch to image content before the text `displayModel` branch.
- Show a compact spinner during loading.
- Show `ImageDiffComparisonContent(..., boundedHeight: 360)`.
- Show a Retry button when either side is `.failed`.
- Start `.task(id: file.imageProvider?.id)`.
- Leave `allowsDraftCommentCreation` unused for image content so no line anchor is synthesized.

- [ ] **Step 4: Run lifecycle, equality, and surface tests**

```bash
ALAS_FFF_TARGET_ARCH=arm64 rtk xcodebuild \
  -project Alas.xcodeproj \
  -scheme Alas \
  -destination 'platform=macOS' \
  -only-testing:AlasTests/DiffReviewImageStateTests \
  -only-testing:AlasTests/DiffReviewRenderableContentEqualityTests \
  -only-testing:AlasTests/DiffReviewSurfaceTests \
  test
```

Expected: PASS, including new accessibility assertions for one header, loading, failure, and retry markers.

- [ ] **Step 5: Commit**

```bash
rtk git add \
  Alas/Sources/Center/DiffReview/DiffReviewImageState.swift \
  Alas/Sources/Center/DiffReview/DiffReviewModels.swift \
  Alas/Sources/Center/DiffReview/DiffReviewFileSection.swift \
  AlasTests/DiffReviewImageStateTests.swift \
  AlasTests/DiffReviewRenderableContentEqualityTests.swift \
  AlasTests/DiffReviewSurfaceTests.swift \
  Alas.xcodeproj/project.pbxproj
rtk git commit -m "feat(review): render lazy inline image diffs"
```

---

### Task 5: Attach working-copy, staged, and commit image providers

**Files:**
- Modify: `Alas/Sources/Center/ImageDiff/GitService+ImageDiff.swift:1-240`
- Modify: `Alas/Sources/Center/ReviewChanges/ReviewChangesLoader.swift:1-135`
- Modify: `Alas/Sources/Center/Commit/StagedDiffLoader.swift:1-112`
- Modify: `Alas/Sources/Center/Commit/CommitReviewLoader.swift:1-134`
- Modify: `AlasTests/ImageDiffPairLoaderTests.swift`
- Modify: `AlasTests/ReviewChangesLoaderTests.swift`
- Modify: `AlasTests/StagedDiffLoaderTests.swift`
- Modify: `AlasTests/CommitReviewLoaderTests.swift`

**Interfaces:**
- Consumes: `DiffReviewImageProvider`, `ImageDiffDecodedCache`, and existing working-copy and commit pair semantics.
- Produces: `GitService.imageSide(worktreePath:revision:path:)`, `workingCopyImageProvider(...)`, `stagedImageProvider(...)`, and `commitImageProvider(...)`.

- [ ] **Step 1: Change placeholder tests into provider tests**

For each loader, assert:

```swift
let file = try #require(session.files.first)
#expect(file.summary.isRenderable)
#expect(file.displayModel == nil)
#expect(file.placeholderMessage == nil)
#expect(file.imageProvider != nil)
```

In `ReviewChangesLoaderTests`, invoke the provider from a fake image-capable client and assert the requested path and stage. In `CommitReviewLoaderTests`, assert the provider passes the exact commit SHA and `CommitChangedFile`, including `originalPath`.

- [ ] **Step 2: Run the four focused suites**

```bash
ALAS_FFF_TARGET_ARCH=arm64 rtk xcodebuild \
  -project Alas.xcodeproj \
  -scheme Alas \
  -destination 'platform=macOS' \
  -only-testing:AlasTests/ImageDiffPairLoaderTests \
  -only-testing:AlasTests/ReviewChangesLoaderTests \
  -only-testing:AlasTests/StagedDiffLoaderTests \
  -only-testing:AlasTests/CommitReviewLoaderTests \
  test
```

Expected: FAIL because images still become placeholders.

- [ ] **Step 3: Add local provider factories and attach them**

Expose provider factories from `GitService+ImageDiff.swift`:

```swift
func imageSide(
    worktreePath: URL,
    revision: String,
    path: String
) async -> ImageDiffSide

func workingCopyImageProvider(
    worktreePath: URL,
    change: ChangedFile
) async -> DiffReviewImageProvider

func stagedImageProvider(
    worktreePath: URL,
    file: CommitChangedFile
) async -> DiffReviewImageProvider

func commitImageProvider(
    worktreePath: URL,
    sha: String,
    file: CommitChangedFile
) -> DiffReviewImageProvider
```

`imageSide` treats an expected absent side only when the factory requests `.missing`; a failed Git command, LFS lookup, or decode returns `.failed` with a concise message. Log the underlying source, revision, path, and diagnostic through the existing image-diff logger, but put only the sanitized category (`Git`, `LFS`, `decode`, or changed-on-disk) in `ImageDiffLoadFailure.message`. Immutable revisions use `ImageDiffDecodedCache.shared`; the working-tree and mutable index paths bypass the immutable cache unless the provider resolved an object ID.

Use repository path, stage or exact SHA, old/current paths, and a mutable file metadata token in the provider ID. Resolve the index object ID with `git rev-parse :path` while creating staged or unstaged providers; this is metadata-only and does not decode the image. Each closure calls `imageSide` independently for before and after, so one failure does not discard the successful side.

In each loader use:

```swift
let isImage = ImageFileType.isSupported(relativePath: file.path)
    || file.originalPath.map(ImageFileType.isSupported(relativePath:)) == true
let canRenderText = !diff.hunks.isEmpty && !isImage
```

Set `summary.isRenderable` to `isImage || canRenderText`, set `imageProvider` for images, and reserve `placeholderMessage` for empty text or unsupported binary files.

For `ReviewChangesGitClient`, `StagedDiffGitClient`, and `CommitReviewGitClient`, add image-provider methods with production conformance in `GitService` and test-fake implementations that return recorded providers.

- [ ] **Step 4: Run focused tests**

Run the Step 2 command.

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
rtk git add \
  Alas/Sources/Center/ImageDiff/GitService+ImageDiff.swift \
  Alas/Sources/Center/ReviewChanges/ReviewChangesLoader.swift \
  Alas/Sources/Center/Commit/StagedDiffLoader.swift \
  Alas/Sources/Center/Commit/CommitReviewLoader.swift \
  AlasTests/ImageDiffPairLoaderTests.swift \
  AlasTests/ReviewChangesLoaderTests.swift \
  AlasTests/StagedDiffLoaderTests.swift \
  AlasTests/CommitReviewLoaderTests.swift
rtk git commit -m "feat(diff): add images to local review surfaces"
```

---

### Task 6: Add exact range and draft-review image providers

**Files:**
- Modify: `Alas/Sources/Git/GitService.swift:288-345,474-500`
- Modify: `Alas/Sources/Center/ImageDiff/GitService+ImageDiff.swift`
- Modify: `Alas/Sources/Center/ReviewWorkspace/RangeReviewLoader.swift:1-145`
- Modify: `Alas/Sources/Center/ReviewRequest/DraftReviewRequestDiffSessionBuilder.swift:1-142`
- Modify: `Alas/Sources/Center/ReviewRequest/DraftReviewRequestTabView.swift:550-590`
- Modify: `Alas/Sources/Center/ReviewWorkspace/ReviewSessionLoader.swift:180-215`
- Modify: `AlasTests/RangeReviewLoaderTests.swift`
- Modify: `AlasTests/Integrations/ReviewRequestDraftTests.swift`
- Modify: `AlasTests/ImageDiffPairLoaderTests.swift`

**Interfaces:**
- Consumes: `DiffReviewImageProvider`, Git range resolution.
- Produces: `GitService.imageDiffPairForRange(...)`, `rangeImageProvider(...)`, and `DraftReviewRequestDiffSessionBuilder.build(..., imageProviderForFile:)`.

- [ ] **Step 1: Write failing two-dot, three-dot, and draft tests**

Add end-to-end image fixtures proving:

```swift
let twoDot = try await GitService().imageDiffPairForRange(
    worktreePath: repo,
    base: "\(rootSHA)^",
    head: headSHA,
    threeDot: false,
    file: file
)
#expect(twoDot.kind == .added)
#expect(twoDot.beforeImage == nil)
#expect(twoDot.afterImage != nil)
```

Add a diverged-branch test where three-dot uses the merge-base image rather than the current base tip.

Change range and draft loader image-placeholder assertions to require a non-nil provider. In draft tests inject:

```swift
imageProviderForFile: { file in
    recordedPaths.append(file.path)
    return imageProvider(path: file.path, before: "merge-base", after: "head")
}
```

Define the test helper in the same file:

```swift
@MainActor
private func imageProvider(
    path: String,
    before: String,
    after: String
) -> DiffReviewImageProvider {
    DiffReviewImageProvider(
        id: DiffReviewImageProviderID(
            source: .range,
            repository: "/tmp/repo",
            beforeRevision: before,
            afterRevision: after,
            beforePath: path,
            afterPath: path
        ),
        load: {
            ImageDiffPair(
                before: .missing,
                after: .missing,
                oldPath: nil,
                kind: .modified
            )
        }
    )
}
```

- [ ] **Step 2: Run focused tests**

```bash
ALAS_FFF_TARGET_ARCH=arm64 rtk xcodebuild \
  -project Alas.xcodeproj \
  -scheme Alas \
  -destination 'platform=macOS' \
  -only-testing:AlasTests/ImageDiffPairLoaderTests \
  -only-testing:AlasTests/RangeReviewLoaderTests \
  -only-testing:AlasTests/ReviewRequestDraftTests \
  test
```

Expected: FAIL because range image pairs and draft image-provider injection do not exist.

- [ ] **Step 3: Implement exact range loading**

Make range-left resolution internal to `GitService`:

```swift
func resolvedRangeTrees(
    worktreePath: URL,
    base: String,
    head: String,
    threeDot: Bool
) async throws -> (before: String, after: String)
```

It uses `mergeBase` for three-dot, `resolveTwoDotLeftTree` for two-dot, and `rev-parse --verify` for the head. Reuse it in both `rangeDiff` and `imageDiffPairForRange` so text and image semantics cannot drift.

Add:

```swift
func imageDiffPairForRange(
    worktreePath: URL,
    base: String,
    head: String,
    threeDot: Bool,
    file: CommitChangedFile
) async throws -> ImageDiffPair

func rangeImageProvider(
    worktreePath: URL,
    revisions: (before: String, after: String),
    file: CommitChangedFile
) -> DiffReviewImageProvider
```

`RangeReviewLoader` resolves the trees once per session and attaches providers to image files.

Add this builder parameter:

```swift
imageProviderForFile: @escaping (CommitChangedFile) -> DiffReviewImageProvider? = { _ in nil }
```

Both production callers resolve the draft's merge-base/head and supply range providers. The builder marks an image renderable only when the closure returns a provider.

- [ ] **Step 4: Run focused tests**

Run the Step 2 command.

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
rtk git add \
  Alas/Sources/Git/GitService.swift \
  Alas/Sources/Center/ImageDiff/GitService+ImageDiff.swift \
  Alas/Sources/Center/ReviewWorkspace/RangeReviewLoader.swift \
  Alas/Sources/Center/ReviewRequest/DraftReviewRequestDiffSessionBuilder.swift \
  Alas/Sources/Center/ReviewRequest/DraftReviewRequestTabView.swift \
  Alas/Sources/Center/ReviewWorkspace/ReviewSessionLoader.swift \
  AlasTests/RangeReviewLoaderTests.swift \
  AlasTests/Integrations/ReviewRequestDraftTests.swift \
  AlasTests/ImageDiffPairLoaderTests.swift
rtk git commit -m "feat(diff): add images to range reviews"
```

---

### Task 7: Render tracked and untracked stash image diffs

**Files:**
- Modify: `Alas/Sources/Git/GitService+Stash.swift:1-190`
- Modify: `Alas/Sources/Center/ImageDiff/GitService+ImageDiff.swift`
- Modify: `Alas/Sources/Center/StashDiffTabView.swift:1-108`
- Modify: `AlasTests/GitServiceStashTests.swift`
- Modify: `AlasTests/ImageDiffPairLoaderTests.swift`

**Interfaces:**
- Consumes: `ImageDiffView`, stash first and third parents.
- Produces: `GitStashFile.isUntracked`, `GitService.imageDiffPairForStash(...)`.

- [ ] **Step 1: Write failing tracked and untracked stash image tests**

Add:

```swift
@Test func stashImagePairUsesFirstParentAndStashSnapshot() async throws {
    let fixture = try await StashImageFixture.modified()
    defer { fixture.remove() }

    let pair = try await GitService().imageDiffPairForStash(
        worktreePath: fixture.repo,
        stash: fixture.stash,
        file: fixture.file
    )

    #expect(pair.kind == .modified)
    #expect(pair.beforeImage != nil)
    #expect(pair.afterImage != nil)
}

@Test func untrackedStashImageHasMissingBeforeAndThirdParentAfter() async throws {
    let fixture = try await StashImageFixture.untracked()
    defer { fixture.remove() }

    let pair = try await GitService().imageDiffPairForStash(
        worktreePath: fixture.repo,
        stash: fixture.stash,
        file: fixture.file
    )

    #expect(fixture.file.isUntracked)
    #expect(pair.kind == .added)
    #expect(pair.beforeImage == nil)
    #expect(pair.afterImage != nil)
}
```

Define the fixture in `GitServiceStashTests.swift`:

```swift
private struct StashImageFixture {
    let repo: URL
    let stash: GitStash
    let file: GitStashFile

    func remove() {
        try? FileManager.default.removeItem(at: repo)
    }

    static func modified() async throws -> Self {
        let repo = try await makeRepo()
        let url = repo.appendingPathComponent("logo.png")
        try red.write(to: url)
        try await git(["add", "logo.png"], cwd: repo)
        try await git(["commit", "-q", "-m", "add image"], cwd: repo)
        try blue.write(to: url)
        _ = try await GitService().pushStash(
            worktreePath: repo,
            message: "image",
            includeUntracked: false
        )
        return try await fixture(repo: repo, path: "logo.png")
    }

    static func untracked() async throws -> Self {
        let repo = try await makeRepo()
        try red.write(to: repo.appendingPathComponent("new.png"))
        _ = try await GitService().pushStash(
            worktreePath: repo,
            message: "untracked image",
            includeUntracked: true
        )
        return try await fixture(repo: repo, path: "new.png")
    }

    private static func fixture(repo: URL, path: String) async throws -> Self {
        let service = GitService()
        let stash = try #require(try await service.stashes(worktreePath: repo).first)
        let file = try #require(
            try await service.stashFiles(worktreePath: repo, stash: stash)
                .first { $0.path == path }
        )
        return Self(repo: repo, stash: stash, file: file)
    }

    private static func makeRepo() async throws -> URL {
        let repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-stash-image-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try await git(["init", "-q", "-b", "main"], cwd: repo)
        try await git(["config", "user.email", "t@example.com"], cwd: repo)
        try await git(["config", "user.name", "Test User"], cwd: repo)
        try "seed\n".write(
            to: repo.appendingPathComponent("seed.txt"),
            atomically: true,
            encoding: .utf8
        )
        try await git(["add", "seed.txt"], cwd: repo)
        try await git(["commit", "-q", "-m", "seed"], cwd: repo)
        return repo
    }

    private static func git(_ args: [String], cwd: URL) async throws {
        let result = try await Process.git(args, cwd: cwd)
        guard result.exitCode == 0 else {
            throw ProcessError.nonZeroExit(result.exitCode, result.stderr)
        }
    }

    private static let red = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC"
    )!
    private static let blue = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGNgYPgPAAEDAQAIicLsAAAAAElFTkSuQmCC"
    )!
}
```

- [ ] **Step 2: Run stash and image loader tests**

```bash
ALAS_FFF_TARGET_ARCH=arm64 rtk xcodebuild \
  -project Alas.xcodeproj \
  -scheme Alas \
  -destination 'platform=macOS' \
  -only-testing:AlasTests/GitServiceStashTests \
  -only-testing:AlasTests/ImageDiffPairLoaderTests \
  test
```

Expected: FAIL because stash origin and image pair APIs do not exist.

- [ ] **Step 3: Preserve stash origin and add image rendering**

Add `isUntracked: Bool = false` to `GitStashFile`, including backward-compatible decoding with `decodeIfPresent`.

Parse tracked and third-parent file lists separately, and add `--find-copies` beside the existing rename detection when listing and diffing stash files:

```swift
let tracked = Self.parseStashFiles(
    numstat: numstat.stdout,
    nameStatus: nameStatus.stdout,
    isUntracked: false
)
let untracked = Self.parseStashFiles(
    numstat: untrackedNumstat?.stdout ?? "",
    nameStatus: untrackedNameStatus?.stdout ?? "",
    isUntracked: true
)
return tracked + untracked
```

Implement `imageDiffPairForStash`:

```swift
func imageDiffPairForStash(
    worktreePath: URL,
    stash: GitStash,
    file: GitStashFile
) async throws -> ImageDiffPair
```

- Tracked before ref: `\(stash.sha)^1`.
- Tracked after ref: `stash.sha`.
- Untracked before: `.missing`.
- Untracked after ref: `\(stash.sha)^3`.
- Use `oldPath` for rename/copy before sides.

In `StashDiffTabView`, branch on `ImageFileType`, lazily load the pair with `.task(id:)`, and render `ImageDiffView`. Keep the existing text path unchanged.

- [ ] **Step 4: Run focused tests and a quiet build**

```bash
ALAS_FFF_TARGET_ARCH=arm64 rtk xcodebuild \
  -project Alas.xcodeproj \
  -scheme Alas \
  -destination 'platform=macOS' \
  -only-testing:AlasTests/GitServiceStashTests \
  -only-testing:AlasTests/ImageDiffPairLoaderTests \
  test
ALAS_FFF_TARGET_ARCH=arm64 rtk xcodebuild \
  -project Alas.xcodeproj \
  -scheme Alas \
  -destination 'platform=macOS' \
  -quiet build
```

Expected: PASS and `BUILD SUCCEEDED`.

- [ ] **Step 5: Commit**

```bash
rtk git add \
  Alas/Sources/Git/GitService+Stash.swift \
  Alas/Sources/Center/ImageDiff/GitService+ImageDiff.swift \
  Alas/Sources/Center/StashDiffTabView.swift \
  AlasTests/GitServiceStashTests.swift \
  AlasTests/ImageDiffPairLoaderTests.swift
rtk git commit -m "feat(stash): render image diffs"
```

---

### Task 8: Add exact GitHub and GitLab image blob capabilities

**Files:**
- Modify: `Alas/Sources/Integrations/CodeHost/CodeHostModels.swift:403-475`
- Modify: `Alas/Sources/Integrations/CodeHost/CodeHostProvider.swift:1-225`
- Modify: `Alas/Sources/Integrations/CodeHost/GitHubCLIProvider.swift`
- Modify: `Alas/Sources/Integrations/CodeHost/GitLabCLIProvider.swift`
- Modify: `AlasTests/Integrations/GitHubCLIProviderTests.swift`
- Modify: `AlasTests/Integrations/GitLabCLIProviderTests.swift`

**Interfaces:**
- Produces: `CodeHostReviewImageRevisions`, `CodeHostProvider.reviewImageRevisions(...)`, and `CodeHostProvider.reviewFileData(...)`.
- Consumes: Existing command runner, `ReviewRequest`, GitLab diff refs, GitHub compare API.

- [ ] **Step 1: Write failing provider command and decoding tests**

For GitHub, assert the provider:

1. Calls compare with exact base/head SHAs.
2. Parses `merge_base_commit.sha`.
3. Calls contents with `--method GET`, exact ref, and encoded path.
4. Removes base64 whitespace and returns original bytes.

For GitLab, assert the provider:

1. Reuses the diff-ref version matching `request.headSHA`.
2. Returns `base_sha` and `head_sha`.
3. Loads `/repository/files/<encoded-path>` at the exact ref.
4. Decodes base64 content.

Use this shared expectation:

```swift
#expect(revisions == CodeHostReviewImageRevisions(
    beforeSHA: "base-sha",
    afterSHA: "head-sha"
))
#expect(data == Data([0x89, 0x50, 0x4e, 0x47]))
```

- [ ] **Step 2: Run provider tests**

```bash
ALAS_FFF_TARGET_ARCH=arm64 rtk xcodebuild \
  -project Alas.xcodeproj \
  -scheme Alas \
  -destination 'platform=macOS' \
  -only-testing:AlasTests/GitHubCLIProviderTests \
  -only-testing:AlasTests/GitLabCLIProviderTests \
  test
```

Expected: FAIL because the protocol methods and revision model do not exist.

- [ ] **Step 3: Implement provider APIs**

Add:

```swift
struct CodeHostReviewImageRevisions: Equatable, Sendable {
    let beforeSHA: String
    let afterSHA: String
}
```

Add protocol requirements:

```swift
func reviewImageRevisions(
    remote: CodeHostRemote,
    request: ReviewRequest,
    cwd: URL
) async throws -> CodeHostReviewImageRevisions

func reviewFileData(
    remote: CodeHostRemote,
    revision: String,
    path: String,
    cwd: URL
) async throws -> Data
```

Provide default implementations that throw `.unsupportedProvider` so existing test fakes keep compiling.

Add optional `baseSHA` to `ReviewRequest` with a defaulted initializer argument. Preserve it in every `ReviewRequest` copy/update helper in `CodeHostModels.swift`. Populate GitHub `baseRefOid` in list/view JSON. GitHub `reviewImageRevisions` calls the compare endpoint using `baseSHA...headSHA` and returns the merge-base plus head. GitLab delegates to `mergeRequestDiffRefs`.

Both `reviewFileData` implementations request JSON/base64 rather than raw binary through `ProcessResult.stdout`, normalize whitespace, decode `Data(base64Encoded:)`, and throw `.malformedOutput` on invalid data.

- [ ] **Step 4: Run provider tests**

Run the Step 2 command.

Expected: PASS, including fork-shaped `ReviewRequest` fixtures.

- [ ] **Step 5: Commit**

```bash
rtk git add \
  Alas/Sources/Integrations/CodeHost/CodeHostModels.swift \
  Alas/Sources/Integrations/CodeHost/CodeHostProvider.swift \
  Alas/Sources/Integrations/CodeHost/GitHubCLIProvider.swift \
  Alas/Sources/Integrations/CodeHost/GitLabCLIProvider.swift \
  AlasTests/Integrations/GitHubCLIProviderTests.swift \
  AlasTests/Integrations/GitLabCLIProviderTests.swift
rtk git commit -m "feat(review): load exact hosted image blobs"
```

---

### Task 9: Attach hosted PR and MR image providers

**Files:**
- Modify: `Alas/Sources/Integrations/CodeHost/ReviewRequestDiffLoader.swift:1-150`
- Modify: `Alas/Sources/Center/ImageDiff/GitService+ImageDiff.swift`
- Modify: `AlasTests/Integrations/ReviewRequestDiffLoaderTests.swift`
- Modify: `AlasTests/ReviewSessionLoaderTests.swift`

**Interfaces:**
- Consumes: `CodeHostProvider.reviewImageRevisions`, `reviewFileData`, and shared raw-byte decoding.
- Produces: hosted `DiffReviewImageProvider` values in `ReviewRequestDiffLoader`.

- [ ] **Step 1: Write failing hosted loader tests**

Replace the image placeholder expectation with:

```swift
let image = try #require(session.files.first { $0.summary.path == "Assets/logo.png" })
#expect(image.summary.isRenderable)
#expect(image.placeholderMessage == nil)
let provider = try #require(image.imageProvider)

let pair = await provider.load()

#expect(pair.kind == .modified)
#expect(pair.beforeImage != nil)
#expect(pair.afterImage != nil)
#expect(fakeProvider.revisionRequests.count == 1)
#expect(fakeProvider.fileRequests.map(\.revision) == ["base-sha", "head-sha"])
```

Add tests for added, deleted, renamed, copied, provider authentication failure, and a fork request with no local head remote.

- [ ] **Step 2: Run hosted loader and review-session tests**

```bash
ALAS_FFF_TARGET_ARCH=arm64 rtk xcodebuild \
  -project Alas.xcodeproj \
  -scheme Alas \
  -destination 'platform=macOS' \
  -only-testing:AlasTests/ReviewRequestDiffLoaderTests \
  -only-testing:AlasTests/ReviewSessionLoaderTests \
  test
```

Expected: FAIL because hosted images remain placeholders.

- [ ] **Step 3: Build hosted providers from parsed sections**

Keep `ProviderDiffFileSection`'s raw Git status letter in addition to `DiffReviewFileStatus`.

After splitting the provider diff into file sections, resolve `reviewImageRevisions` exactly once when at least one section is image-backed. Catch that metadata error instead of throwing from `load`; image providers created from a failed revision result return a scoped revision-loading failure when rendered.

For an image section with resolved revisions, create an ID using provider kind, remote repository identity, request number, exact before/head SHAs, original path, and current path. The load closure:

1. Uses the captured exact revisions.
2. Loads only required sides for the status.
3. Passes raw bytes through the shared LFS/image decoder.
4. Returns `.failed` for the affected side on provider or decode errors.
5. Maps `C` to `.copied` and `R` to `.renamed`.

Use `ImageDiffDecodedCache.shared` with the exact provider SHA/path key around each hosted `reviewFileData` plus decode operation. Do not cache provider failures.

Log provider kind, review number, revision, path, and the underlying diagnostic using the existing privacy conventions. Map authentication, network/command, LFS, and decode errors to concise UI messages without response bodies or raw command output.

Do not fail `ReviewRequestDiffLoader.load` when image metadata or bytes fail. The error remains inside the lazy provider so text files, rail state, and comments load.

- [ ] **Step 4: Run focused tests**

Run the Step 2 command.

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
rtk git add \
  Alas/Sources/Integrations/CodeHost/ReviewRequestDiffLoader.swift \
  Alas/Sources/Center/ImageDiff/GitService+ImageDiff.swift \
  AlasTests/Integrations/ReviewRequestDiffLoaderTests.swift \
  AlasTests/ReviewSessionLoaderTests.swift
rtk git commit -m "feat(review): render hosted image diffs"
```

---

### Task 10: Show only the resulting image in GG Split Commit

**Files:**
- Modify: `Alas/Sources/Integrations/GG/GGSplitCommitTabView.swift:1-330`
- Modify: `Alas/Sources/Center/CenterPaneView.swift:334-373`
- Modify: `AlasTests/Integrations/GGSplitCommitModelTests.swift`
- Modify: `AlasTests/ImageDiffPairLoaderTests.swift`

**Interfaces:**
- Consumes: exact target SHA, worktree path, shared revision-image decoding.
- Produces: `GGResultingImagePreview` and a `worktreePath` argument on `GGSplitCommitTabView`.

- [ ] **Step 1: Write failing preview-selection and revision-image tests**

Add a pure selection helper test:

```swift
@Test func remainderPreviewClassifiesOnlySupportedImagesForVisualPreview() {
    let paths = ["Assets/logo.png", "Archive/data.zip", "Scripts/run.sh"]

    let result = GGResultingImagePreview.partition(paths)

    #expect(result.imagePaths == ["Assets/logo.png"])
    #expect(result.otherPaths == ["Archive/data.zip", "Scripts/run.sh"])
}
```

Add a Git fixture proving target revision loading ignores the current working-tree file:

```swift
let image = await GitService().imageSide(
    worktreePath: repo,
    revision: targetSHA,
    path: "Assets/logo.png"
)
#expect(image.image != nil)
```

- [ ] **Step 2: Run focused tests**

```bash
ALAS_FFF_TARGET_ARCH=arm64 rtk xcodebuild \
  -project Alas.xcodeproj \
  -scheme Alas \
  -destination 'platform=macOS' \
  -only-testing:AlasTests/GGSplitCommitModelTests \
  -only-testing:AlasTests/ImageDiffPairLoaderTests \
  test
```

Expected: FAIL because the preview helper and revision loader do not exist.

- [ ] **Step 3: Implement resulting-image-only previews**

Pass `worktreePath: worktree.path` from `CenterPaneView` into `GGSplitCommitTabView`.

Add:

```swift
enum GGResultingImagePreview {
    struct Partition: Equatable {
        let imagePaths: [String]
        let otherPaths: [String]
    }

    static func partition(_ paths: [String]) -> Partition {
        Partition(
            imagePaths: paths.filter(ImageFileType.isSupported(relativePath:)),
            otherPaths: paths.filter { !ImageFileType.isSupported(relativePath: $0) }
        )
    }
}
```

For remainder previews:

- Keep text files unchanged.
- Render each `imagePath` with a small lazy view that loads `model.targetSHA` through `GitService.imageSide`.
- Fit proportionally on checkerboard with a bounded 220-point height.
- Show no before side, comparison mode, reset, or assignment control.
- Keep non-image paths as the existing document label.
- First-commit preview receives no non-textual files and therefore no image previews.

- [ ] **Step 4: Run focused tests and quiet build**

```bash
ALAS_FFF_TARGET_ARCH=arm64 rtk xcodebuild \
  -project Alas.xcodeproj \
  -scheme Alas \
  -destination 'platform=macOS' \
  -only-testing:AlasTests/GGSplitCommitModelTests \
  -only-testing:AlasTests/ImageDiffPairLoaderTests \
  test
ALAS_FFF_TARGET_ARCH=arm64 rtk xcodebuild \
  -project Alas.xcodeproj \
  -scheme Alas \
  -destination 'platform=macOS' \
  -quiet build
```

Expected: PASS and `BUILD SUCCEEDED`.

- [ ] **Step 5: Commit**

```bash
rtk git add \
  Alas/Sources/Integrations/GG/GGSplitCommitTabView.swift \
  Alas/Sources/Center/CenterPaneView.swift \
  AlasTests/Integrations/GGSplitCommitModelTests.swift \
  AlasTests/ImageDiffPairLoaderTests.swift
rtk git commit -m "feat(gg): preview remainder images"
```

---

### Task 11: Verify conflict regressions, project generation, and the full feature

**Files:**
- Modify: `AlasTests/MergeConflictBinaryDetectionTests.swift`
- Modify: `AlasTests/ImageDiffEndToEndTests.swift`
- Regenerate: `Alas.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: all prior tasks.
- Produces: a clean generated project and evidence that every required surface builds and tests together.

- [ ] **Step 1: Add final regression assertions**

Add tests that preserve the conflict contract and standalone behavior:

```swift
@Test func conflictImageDetectionStillUsesSupportedImageTypes() {
    #expect(ImageFileType.isSupported(relativePath: "Assets/local.png"))
    #expect(ImageFileType.isSupported(relativePath: "Assets/remote.svg"))
    #expect(!ImageFileType.isSupported(relativePath: "Artifacts/data.zip"))
}

@MainActor
@Test func standalonePairStillDefaultsToSideBySide() {
    let state = ImageDiffPresentationState()
    #expect(state.mode == .sideBySide)
    #expect(state.transform == ImageDiffTransform())
}
```

Keep `MergeConflictBinaryView` unchanged. The regression test must continue to exercise the current `ImageFileType` decision used by that view.

- [ ] **Step 2: Regenerate the project and check generated drift**

```bash
rtk xcodegen
rtk git diff --check
rtk git status --short
```

Expected: no whitespace errors. `Alas.xcodeproj/project.pbxproj` contains every new source and test file.

- [ ] **Step 3: Run the focused feature matrix serially**

```bash
ALAS_FFF_TARGET_ARCH=arm64 rtk xcodebuild \
  -project Alas.xcodeproj \
  -scheme Alas \
  -destination 'platform=macOS' \
  -only-testing:AlasTests/ImageDiffPairResolverTests \
  -only-testing:AlasTests/ImageDiffPairLoaderTests \
  -only-testing:AlasTests/ImageDiffModeApplicabilityTests \
  -only-testing:AlasTests/ImageDiffViewTests \
  -only-testing:AlasTests/ImageDiffDecodedCacheTests \
  -only-testing:AlasTests/DiffReviewImageStateTests \
  -only-testing:AlasTests/DiffReviewRenderableContentEqualityTests \
  -only-testing:AlasTests/ReviewChangesLoaderTests \
  -only-testing:AlasTests/StagedDiffLoaderTests \
  -only-testing:AlasTests/CommitReviewLoaderTests \
  -only-testing:AlasTests/RangeReviewLoaderTests \
  -only-testing:AlasTests/ReviewRequestDraftTests \
  -only-testing:AlasTests/GitServiceStashTests \
  -only-testing:AlasTests/ReviewRequestDiffLoaderTests \
  -only-testing:AlasTests/GitHubCLIProviderTests \
  -only-testing:AlasTests/GitLabCLIProviderTests \
  -only-testing:AlasTests/GGSplitCommitModelTests \
  -only-testing:AlasTests/MergeConflictBinaryDetectionTests \
  test
```

Expected: `TEST SUCCEEDED`.

- [ ] **Step 4: Run required build and full test verification serially**

```bash
ALAS_FFF_TARGET_ARCH=arm64 rtk xcodebuild \
  -project Alas.xcodeproj \
  -scheme Alas \
  -destination 'platform=macOS' \
  -quiet build
ALAS_FFF_TARGET_ARCH=arm64 rtk xcodebuild \
  -project Alas.xcodeproj \
  -scheme Alas \
  -destination 'platform=macOS' \
  test
```

Expected: `BUILD SUCCEEDED` and `TEST SUCCEEDED`.

- [ ] **Step 5: Commit regression or generated-project changes**

```bash
rtk git add \
  AlasTests/MergeConflictBinaryDetectionTests.swift \
  AlasTests/ImageDiffEndToEndTests.swift \
  Alas.xcodeproj/project.pbxproj
rtk git commit -m "test(diff): cover image diffs across panes"
```

Expected: one regression-test commit; adding an unchanged generated project file is harmless.

---

## Final Acceptance Checklist

- [ ] Working-copy staged, unstaged, and compare-with-HEAD tabs retain image diffs.
- [ ] Commit editor retains image diffs.
- [ ] Review Changes, Draft Commit, Commit Details, review workspace, ranges, and draft review requests show full inline image diffs.
- [ ] Stash image diffs use first-parent or untracked-third-parent semantics.
- [ ] GitHub and GitLab image diffs use exact reviewed revisions and work for forks.
- [ ] Added, deleted, modified, renamed, and copied images render accurately.
- [ ] Failed sides are distinct from missing sides and retry locally.
- [ ] Provider changes cancel and reject stale loads.
- [ ] Immutable cache entries are bounded and in-flight loads coalesce.
- [ ] File-level feedback and existing file actions remain available.
- [ ] GG Split Commit shows only the resulting remainder image.
- [ ] Conflict resolution keeps its existing ours/theirs UI.
- [ ] `xcodegen`, quiet build, focused tests, and full tests pass serially.
