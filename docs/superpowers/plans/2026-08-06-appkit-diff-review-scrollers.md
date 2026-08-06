# AppKit Diff and Review Scrollers Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace SwiftUI-owned vertical scrolling in Alas diff and review surfaces with one feature-flagged AppKit hosted-row virtualization engine while preserving the legacy path and all existing behavior.

**Architecture:** A diff-specific `NSScrollView` owns geometry, viewport tracking, stable-ID reconciliation, offset compensation, and pooled `NSHostingView` rows. Shared non-scrolling row views feed three adapters: internally scrolling `DiffPaneView`, the multi-file `DiffReviewSurface`, and the GG split preview. Keyed presentation-state objects keep interactive state alive while rows recycle.

**Tech Stack:** Swift 5.9, SwiftUI, AppKit (`NSScrollView`, `NSHostingView`), Swift Testing, XcodeGen, SwiftFormat, macOS 15+

## Global Constraints

- Keep code, comments, logs, and UI strings in English.
- Use Swift Testing (`import Testing`), not XCTest.
- Keep the existing AppKit diff text renderer and TextKit behavior unchanged.
- Do not modify or generalize the ACP transcript scroller; port only proven algorithms into diff-specific types.
- Preserve text/image rendering, comments, drafts, focus, selection, LSP behavior, context expansion, mutations, accessibility, and render budgets.
- Use one `alas.diff.appKitScroller` override: enabled by default in debug builds and disabled by default in release builds.
- Runtime flag changes rebuild scrolling subtrees and deliberately reset scroll position while preserving parent-owned selections and drafts.
- Do not add analytics, persisted presentation state, wire/schema changes, or elapsed-time CI thresholds.
- Run `rtk xcodegen` after adding source/test files and commit the generated project changes with the owning task.
- Make each implementation task test-first and commit it before starting the next task.

---

## File Map

Create these focused engine files under `Alas/Sources/Center/Diff/Scroller/`:

- `AppKitDiffScrollerFlag.swift` — experiment resolution, persistence, and notification.
- `AppKitDiffRowSpec.swift` — row IDs, equality tokens, plans, retention, scroll requests, and callback-independent metadata.
- `AppKitDiffTilingController.swift` — ordered geometry, anchor calculation, mount bands, active-owner lookup, and target offsets.
- `AppKitDiffRowHostingView.swift` — fixed-width SwiftUI measurement and intrinsic-size invalidation.
- `AppKitDiffRowHostingPool.swift` — mounted entries and reusable host storage.
- `AppKitDiffScrollView.swift` — flipped AppKit document and native scroll notifications.
- `AppKitDiffScrollerReconciler.swift` — stable-ID plan application, measurement caching, mounting, recycling, and anchor compensation.
- `AppKitDiffScroller.swift` — `NSViewRepresentable` coordinator and public internal adapter interface.
- `DiffPaneRowPlan.swift` — non-scrolling hunk row views and standalone row-plan construction.

Create review-specific files under `Alas/Sources/Center/DiffReview/`:

- `AppKitDiffReviewPresentationState.swift` — keyed file state and live action relays.
- `AppKitDiffReviewRowPlan.swift` — flattened review row IDs, tokens, views, and plan builder.
- `AppKitDiffReviewScroller.swift` — review commands, active-file bridging, and the core scroller adapter.

Create `Alas/Sources/Integrations/GG/GGSplitPreviewRowPlan.swift` for the split-preview adapter and keyed resulting-image state.

Tests mirror those boundaries under `AlasTests/Center/Diff/Scroller/`, `AlasTests/Center/DiffReview/`, and `AlasTests/Integrations/GG/`.

### Task 1: Shared Experiment Flag And Settings Toggle

**Files:**
- Create: `Alas/Sources/Center/Diff/Scroller/AppKitDiffScrollerFlag.swift`
- Create: `AlasTests/Center/Diff/Scroller/AppKitDiffScrollerFlagTests.swift`
- Modify: `Alas/Sources/Settings/AdvancedPane.swift`
- Modify: `Alas.xcodeproj/project.pbxproj` via XcodeGen

**Interfaces:**
- Produces: `AppKitDiffScrollerFlag.defaultsKey`, `overrideDidChangeNotification`, `isEnabled`, `resolve(override:isDebugBuild:)`, `readOverride(from:)`, and `setOverride(_:in:notificationCenter:)`.
- Later surface adapters observe `overrideDidChangeNotification` and cache `isEnabled` in local `@State`.

- [ ] **Step 1: Write the failing flag tests**

```swift
import Foundation
import Testing
@testable import Alas

@Suite("AppKitDiffScrollerFlag")
struct AppKitDiffScrollerFlagTests {
    @Test("explicit overrides win and build defaults differ")
    func resolution() {
        #expect(AppKitDiffScrollerFlag.resolve(override: true, isDebugBuild: false))
        #expect(!AppKitDiffScrollerFlag.resolve(override: false, isDebugBuild: true))
        #expect(AppKitDiffScrollerFlag.resolve(override: nil, isDebugBuild: true))
        #expect(!AppKitDiffScrollerFlag.resolve(override: nil, isDebugBuild: false))
    }

    @Test("setOverride persists and broadcasts")
    func persistenceAndNotification() async {
        let suite = "AppKitDiffScrollerFlagTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let center = NotificationCenter()
        defer { defaults.removePersistentDomain(forName: suite) }

        await confirmation { received in
            let token = center.addObserver(
                forName: AppKitDiffScrollerFlag.overrideDidChangeNotification,
                object: nil,
                queue: nil
            ) { _ in received() }
            defer { center.removeObserver(token) }
            AppKitDiffScrollerFlag.setOverride(true, in: defaults, notificationCenter: center)
        }
        #expect(AppKitDiffScrollerFlag.readOverride(from: defaults) == true)
    }
}
```

- [ ] **Step 2: Regenerate and verify the tests fail for the missing type**

Run:

```bash
rtk xcodegen
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test -only-testing:AlasTests/AppKitDiffScrollerFlagTests
```

Expected: compilation fails because `AppKitDiffScrollerFlag` is undefined.

- [ ] **Step 3: Implement the flag with the approved contract**

```swift
import Foundation

enum AppKitDiffScrollerFlag {
    static let defaultsKey = "alas.diff.appKitScroller"
    static let overrideDidChangeNotification = Notification.Name(
        "io.nlopez.alas.AppKitDiffScrollerFlag.overrideDidChange"
    )

    static var isEnabled: Bool { isEnabledWithDefaults(.standard) }

    nonisolated static func readOverride(from defaults: UserDefaults) -> Bool? {
        defaults.object(forKey: defaultsKey) as? Bool
    }

    nonisolated static func isEnabledWithDefaults(_ defaults: UserDefaults) -> Bool {
        #if DEBUG
        resolve(override: readOverride(from: defaults), isDebugBuild: true)
        #else
        resolve(override: readOverride(from: defaults), isDebugBuild: false)
        #endif
    }

    nonisolated static func resolve(override: Bool?, isDebugBuild: Bool) -> Bool {
        override ?? isDebugBuild
    }

    nonisolated static func setOverride(
        _ override: Bool,
        in defaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = .default
    ) {
        defaults.set(override, forKey: defaultsKey)
        notificationCenter.post(name: overrideDidChangeNotification, object: nil)
    }
}
```

- [ ] **Step 4: Add the Settings row and observable toggle state**

Add `@State private var appKitDiffScrollerEnabled = AppKitDiffScrollerFlag.isEnabled`, a second `SettingsRow` named `AppKit diff scrollers`, and a second notification observer. Use this exact description:

```swift
"Replaces vertical scrolling in diff and review panes with an AppKit-backed scroller. Toggling this re-creates open diff views, so their scroll positions are lost."
```

- [ ] **Step 5: Run the focused tests and commit**

```bash
rtk xcodegen
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test -only-testing:AlasTests/AppKitDiffScrollerFlagTests
git add Alas/Sources/Center/Diff/Scroller/AppKitDiffScrollerFlag.swift Alas/Sources/Settings/AdvancedPane.swift AlasTests/Center/Diff/Scroller/AppKitDiffScrollerFlagTests.swift Alas.xcodeproj/project.pbxproj
git commit -m "feat(diff): add AppKit scroller experiment flag"
```

Expected: focused tests pass.

### Task 2: Row Plan And Tiling Geometry

**Files:**
- Create: `Alas/Sources/Center/Diff/Scroller/AppKitDiffRowSpec.swift`
- Create: `Alas/Sources/Center/Diff/Scroller/AppKitDiffTilingController.swift`
- Create: `AlasTests/Center/Diff/Scroller/AppKitDiffTilingControllerTests.swift`
- Modify: `Alas.xcodeproj/project.pbxproj` via XcodeGen

**Interfaces:**
- Produces: `AppKitDiffRowEqualityToken`, `AppKitDiffRowRetention`, `AppKitDiffRowSpec`, `AppKitDiffRowPlan`, `AppKitDiffScrollAlignment`, `AppKitDiffScrollRequest`, `AppKitDiffScrollAnchor`, and `AppKitDiffTilingController`.
- Row IDs and owner IDs are `String`; review adapters use `DiffReviewFileID.rawValue` as `ownerID`.
- `AppKitDiffTilingController.RowLayout` stores `id`, `ownerID`, `height`, and `minY`.

- [ ] **Step 1: Write failing geometry tests**

```swift
import CoreGraphics
import Testing
@testable import Alas

@Suite("AppKit diff tiling")
struct AppKitDiffTilingControllerTests {
    @Test("mount band stays bounded and active owner follows the viewport")
    func mountBandAndOwner() {
        let tiling = AppKitDiffTilingController(metrics: .init(rowSpacing: 0, topPadding: 0, bottomPadding: 0))
        tiling.replaceAll(rows: (0..<100).map {
            .init(id: "row-\($0)", ownerID: "file-\($0 / 10)", height: 20)
        })
        #expect(tiling.mountBand(viewportMinY: 800, viewportHeight: 100, overscan: 100) == 35..<50)
        #expect(tiling.activeOwnerID(viewportMinY: 800, viewportHeight: 100) == "file-4")
    }

    @Test("height growth above the viewport returns exact compensation")
    func heightCompensation() {
        let tiling = AppKitDiffTilingController(metrics: .init(rowSpacing: 0, topPadding: 0, bottomPadding: 0))
        tiling.replaceAll(rows: [
            .init(id: "a", ownerID: nil, height: 100),
            .init(id: "b", ownerID: nil, height: 100),
        ])
        #expect(tiling.updateHeight(id: "a", to: 140, viewportMinY: 100) == 40)
        #expect(tiling.row(withID: "b")?.minY == 140)
    }

    @Test("anchor records intra-row position and resolves after reorder")
    func anchorRestoration() {
        let tiling = AppKitDiffTilingController(metrics: .init(rowSpacing: 0, topPadding: 0, bottomPadding: 0))
        tiling.replaceAll(rows: [
            .init(id: "a", ownerID: nil, height: 100),
            .init(id: "b", ownerID: nil, height: 100),
        ])
        let anchor = tiling.anchor(viewportMinY: 130)
        #expect(anchor == .init(rowID: "b", intraRowOffset: 30))
        tiling.replaceAll(rows: [
            .init(id: "x", ownerID: nil, height: 50),
            .init(id: "a", ownerID: nil, height: 100),
            .init(id: "b", ownerID: nil, height: 100),
        ])
        #expect(tiling.viewportMinY(for: anchor) == 180)
    }
}
```

- [ ] **Step 2: Run the tests and confirm missing-type failures**

```bash
rtk xcodegen
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test -only-testing:AlasTests/AppKitDiffTilingControllerTests
```

- [ ] **Step 3: Implement row-plan values**

```swift
struct AppKitDiffRowSpec {
    let id: String
    let ownerID: String?
    let equalityToken: AppKitDiffRowEqualityToken
    let estimatedHeight: CGFloat
    var retention: AppKitDiffRowRetention = .recyclable
    let build: () -> AnyView
}

struct AppKitDiffRowPlan {
    let rows: [AppKitDiffRowSpec]
}

enum AppKitDiffRowRetention: Equatable { case recyclable, pinned }
enum AppKitDiffScrollAlignment: Equatable { case top, center }

struct AppKitDiffScrollRequest: Equatable {
    let targetID: String
    let fallbackID: String?
    let alignment: AppKitDiffScrollAlignment
    let animated: Bool
    let generation: Int
}

struct AppKitDiffScrollAnchor: Equatable {
    let rowID: String
    let intraRowOffset: CGFloat
}
```

Implement `AppKitDiffRowEqualityToken` with the same type-erased `Equatable` contract as `ACPRowEqualityToken`, but do not import or reference the ACP type.

- [ ] **Step 4: Implement the tiling controller**

Provide these exact methods:

```swift
func replaceAll(rows: [Seed])
func row(withID id: String) -> RowLayout?
func index(ofID id: String) -> Int?
func updateHeight(id: String, to height: CGFloat, viewportMinY: CGFloat) -> CGFloat
func anchor(viewportMinY: CGFloat) -> AppKitDiffScrollAnchor?
func viewportMinY(for anchor: AppKitDiffScrollAnchor?) -> CGFloat?
func mountBand(viewportMinY: CGFloat, viewportHeight: CGFloat, overscan: CGFloat) -> Range<Int>
func activeOwnerID(viewportMinY: CGFloat, viewportHeight: CGFloat) -> String?
func targetOffset(id: String, alignment: AppKitDiffScrollAlignment, viewportHeight: CGFloat) -> CGFloat?
```

Use half-open row ranges, binary search for the first intersecting row, and deterministic last-entry ID lookup after a debug assertion on duplicates.

- [ ] **Step 5: Add boundary tests and commit**

Add cases for empty plans, past-end viewports, center-offset clamping, duplicate IDs, top/bottom padding, and a height change within the viewport returning zero compensation.

```bash
rtk xcodegen
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test -only-testing:AlasTests/AppKitDiffTilingControllerTests
git add Alas/Sources/Center/Diff/Scroller/AppKitDiffRowSpec.swift Alas/Sources/Center/Diff/Scroller/AppKitDiffTilingController.swift AlasTests/Center/Diff/Scroller/AppKitDiffTilingControllerTests.swift Alas.xcodeproj/project.pbxproj
git commit -m "feat(diff): add AppKit row tiling model"
```

### Task 3: Hosting View And Reuse Pool

**Files:**
- Create: `Alas/Sources/Center/Diff/Scroller/AppKitDiffRowHostingView.swift`
- Create: `Alas/Sources/Center/Diff/Scroller/AppKitDiffRowHostingPool.swift`
- Create: `AlasTests/Center/Diff/Scroller/AppKitDiffRowHostingPoolTests.swift`
- Modify: `Alas.xcodeproj/project.pbxproj` via XcodeGen

**Interfaces:**
- Consumes: `AppKitDiffRowSpec` and `AppKitDiffRowEqualityToken` from Task 2.
- Produces: `AppKitDiffRowHostingView.measuredHeight(forWidth:)`, `updateRootView(_:)`, and `AppKitDiffRowHostingPool.view(for:)`, `release(id:)`, `releaseAll(except:)`, `mountedView(id:)`, `mountedIDs`.

- [ ] **Step 1: Write failing pool tests**

```swift
import SwiftUI
import Testing
@testable import Alas

@MainActor
@Suite("AppKit diff hosting pool")
struct AppKitDiffRowHostingPoolTests {
    @Test("equal tokens retain the root and changed tokens update it")
    func equalityGating() {
        let pool = AppKitDiffRowHostingPool()
        var builds = 0
        func spec(_ value: Int) -> AppKitDiffRowSpec {
            .init(
                id: "row", ownerID: nil,
                equalityToken: .init(value), estimatedHeight: 20
            ) {
                builds += 1
                return AnyView(Text("\(value)"))
            }
        }
        let first = pool.view(for: spec(1))
        let unchanged = pool.view(for: spec(1))
        let changed = pool.view(for: spec(2))
        #expect(first.view === unchanged.view)
        #expect(first.view === changed.view)
        #expect(builds == 2)
    }

    @Test("released hosts are reused for a different row")
    func reuse() {
        let pool = AppKitDiffRowHostingPool()
        func spec(_ id: String) -> AppKitDiffRowSpec {
            .init(
                id: id,
                ownerID: nil,
                equalityToken: .init(id),
                estimatedHeight: 20
            ) { AnyView(Text(id)) }
        }
        let first = pool.view(for: spec("a")).view
        pool.release(id: "a")
        let second = pool.view(for: spec("b")).view
        #expect(first === second)
    }
}
```

- [ ] **Step 2: Run the tests and confirm missing-type failures**

```bash
rtk xcodegen
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test -only-testing:AlasTests/AppKitDiffRowHostingPoolTests
```

- [ ] **Step 3: Implement fixed-width hosting measurement**

Port the ACP hosting-view invariants into the diff-specific class: retain an unwrapped `baseRootView`, set `sizingOptions = [.intrinsicContentSize]`, pin the root to the positive measurement width, record `lastMeasuredWidth`, and invoke `onIntrinsicSizeInvalidated` from `invalidateIntrinsicContentSize()`.

```swift
@MainActor
final class AppKitDiffRowHostingView: NSHostingView<AnyView> {
    var representedRowID: String?
    var onIntrinsicSizeInvalidated: ((String) -> Void)?
    private var baseRootView: AnyView
    private(set) var lastMeasuredWidth: CGFloat?

    func updateRootView(_ newRootView: AnyView)
    func measuredHeight(forWidth width: CGFloat) -> CGFloat
}
```

- [ ] **Step 4: Implement bounded reuse**

The pool keeps mounted entries keyed by ID and at most 32 detached reusable hosts. Reassign `representedRowID` whenever a host is mounted so intrinsic-size callbacks cannot report the old row ID.

- [ ] **Step 5: Add measurement and callback tests, then commit**

Cover zero-width measurement leaving the previous root/width untouched, width-dependent text height, callback ID reassignment after reuse, and `releaseAll(except:)` preserving pinned IDs.

```bash
rtk xcodegen
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test -only-testing:AlasTests/AppKitDiffRowHostingPoolTests
git add Alas/Sources/Center/Diff/Scroller/AppKitDiffRowHostingView.swift Alas/Sources/Center/Diff/Scroller/AppKitDiffRowHostingPool.swift AlasTests/Center/Diff/Scroller/AppKitDiffRowHostingPoolTests.swift Alas.xcodeproj/project.pbxproj
git commit -m "feat(diff): pool AppKit hosted rows"
```

### Task 4: Native Scroll View And Reconciler

**Files:**
- Create: `Alas/Sources/Center/Diff/Scroller/AppKitDiffScrollView.swift`
- Create: `Alas/Sources/Center/Diff/Scroller/AppKitDiffScrollerReconciler.swift`
- Create: `AlasTests/Center/Diff/Scroller/AppKitDiffScrollerReconcilerTests.swift`
- Modify: `Alas.xcodeproj/project.pbxproj` via XcodeGen

**Interfaces:**
- Consumes: Tasks 2-3 geometry and host APIs.
- Produces: `AppKitDiffScrollView` with `scrollY`, `viewportHeight`, `contentWidth`, `setScrollY(_:animated:)`, `onViewportChange`, and `onContentWidthChange`; `AppKitDiffScrollerReconciler.apply(plan:contentWidth:)`, `layoutVisibleRows()`, and `scroll(to:)`.
- Under `#if DEBUG`, the reconciler also exposes read-only `fullPlanApplyCountForTests` and `layoutPassCountForTests` counters used only by deterministic tests.

- [ ] **Step 1: Write failing reconciler tests in a real `NSWindow`**

Create a helper that mounts a 400×240 `AppKitDiffScrollView`, tiler, pool, and reconciler in a key window. Test that applying 200 fixed-height rows mounts fewer than 40 hosts, scrolling to row 150 mounts that band, and adding a row above the viewport preserves a chosen row's screen-space position.

```swift
let before = tiling.row(withID: "row-150")!.minY - scrollView.scrollY
reconciler.apply(plan: planWithPrependedRow, contentWidth: scrollView.contentWidth)
let after = tiling.row(withID: "row-150")!.minY - scrollView.scrollY
#expect(abs(before - after) < 0.5)
```

- [ ] **Step 2: Run the tests and confirm missing-type failures**

```bash
rtk xcodegen
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test -only-testing:AlasTests/AppKitDiffScrollerReconcilerTests
```

- [ ] **Step 3: Implement `AppKitDiffScrollView`**

Use a flipped document view, vertical scroller, no background, no horizontal scroller, and clip-view bounds notifications. Programmatic adjustment depth must suppress active-owner callbacks during internal compensation. `layout()` reports positive content-width changes and height-only viewport changes.

- [ ] **Step 4: Implement stable-ID reconciliation**

`apply` must:

1. return without changing live content for width `<= 0`
2. capture the top anchor and current measured heights
3. build tiling seeds using cached measured height by stable ID or the new estimate
4. replace the tiling rows
5. restore the anchor and resize the document view
6. mount and measure the viewport-plus-800-point overscan band
7. repeat placement if measurement changes geometry
8. release unneeded hosts except rows whose retention is `.pinned`

Guard the repeat loop at three passes; schedule one deferred pass if intrinsic-size invalidation arrives during reconciliation.

- [ ] **Step 5: Add update and recovery tests**

Cover unchanged-token no-op, changed-token remeasurement, insertion/removal/reorder, content-width invalidation, height-only resize, zero-width first update followed by recovery, pinned offscreen rows, intrinsic-size coalescing, center and top target offsets, and missing target fallback.

- [ ] **Step 6: Run and commit**

```bash
rtk xcodegen
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test -only-testing:AlasTests/AppKitDiffScrollerReconcilerTests
git add Alas/Sources/Center/Diff/Scroller/AppKitDiffScrollView.swift Alas/Sources/Center/Diff/Scroller/AppKitDiffScrollerReconciler.swift AlasTests/Center/Diff/Scroller/AppKitDiffScrollerReconcilerTests.swift Alas.xcodeproj/project.pbxproj
git commit -m "feat(diff): reconcile AppKit scroll rows"
```

### Task 5: SwiftUI Representable And Scroll Commands

**Files:**
- Create: `Alas/Sources/Center/Diff/Scroller/AppKitDiffScroller.swift`
- Create: `AlasTests/Center/Diff/Scroller/AppKitDiffScrollerTests.swift`
- Modify: `Alas.xcodeproj/project.pbxproj` via XcodeGen

**Interfaces:**
- Consumes: `AppKitDiffRowPlan`, `AppKitDiffScrollRequest`, and Task 4 reconciler.
- Produces:

```swift
struct AppKitDiffScroller: NSViewRepresentable {
    let plan: AppKitDiffRowPlan
    let scrollRequest: AppKitDiffScrollRequest?
    let onActiveOwnerChange: (String?) -> Void
}
```

- [ ] **Step 1: Write failing representable/coordinator tests**

Test that `update(plan:)` applies a changed plan, consumes each request generation once, resolves `fallbackID` when `targetID` is absent, reports active owner only on a user-driven viewport change, and dismantling releases observers and hosted rows.

- [ ] **Step 2: Run the focused tests and confirm failure**

```bash
rtk xcodegen
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test -only-testing:AlasTests/AppKitDiffScrollerTests
```

- [ ] **Step 3: Implement the coordinator**

Cache the most recent plan, last consumed request generation, and latest active owner. Wire width changes to full `apply`, height/scroll changes to `layoutVisibleRows`, and user-driven scroll callbacks to `tiling.activeOwnerID`. Programmatic target scrolling must not emit intermediate active-owner changes.

- [ ] **Step 4: Run tests and commit**

```bash
rtk xcodegen
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test -only-testing:AlasTests/AppKitDiffScrollerTests
git add Alas/Sources/Center/Diff/Scroller/AppKitDiffScroller.swift AlasTests/Center/Diff/Scroller/AppKitDiffScrollerTests.swift Alas.xcodeproj/project.pbxproj
git commit -m "feat(diff): bridge AppKit row scroller to SwiftUI"
```

### Task 6: Extract Reusable Diff Hunk Rows

**Files:**
- Create: `Alas/Sources/Center/Diff/Scroller/DiffPaneRowPlan.swift`
- Create: `AlasTests/Center/Diff/Scroller/DiffPaneRowPlanTests.swift`
- Modify: `Alas/Sources/Center/Diff/DiffPaneView.swift`
- Modify: `AlasTests/DiffPaneViewTests.swift`
- Modify: `Alas.xcodeproj/project.pbxproj` via XcodeGen

**Interfaces:**
- Produces: `DiffPanePresentationState`, `DiffPaneHunkRowToken`, `DiffPaneHunkRow`, and `DiffPaneRowPlanBuilder`.
- `DiffPaneRowPlanBuilder` accepts the same rendering inputs as `DiffPaneView` plus a shared presentation state and returns an `AppKitDiffRowPlan`.
- This task refactors rendering only; `DiffPaneView` still selects the legacy SwiftUI scroll path until Task 7.

- [ ] **Step 1: Write row identity tests**

Create a two-hunk `DiffDisplayModel` and assert the builder returns two unique IDs, stable IDs for an identical rebuild, changed equality tokens after wrap/layout/whitespace/font or row-signature changes, and unchanged tokens when only action closure identity changes.

```swift
let first = DiffPaneRowPlanBuilder.build(input: input, state: state)
let second = DiffPaneRowPlanBuilder.build(input: input, state: state)
#expect(first.rows.map(\.id) == second.rows.map(\.id))
#expect(first.rows[0].equalityToken.isEqual(to: second.rows[0].equalityToken))
```

- [ ] **Step 2: Run the tests and confirm failure**

```bash
rtk xcodegen
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test -only-testing:AlasTests/DiffPaneRowPlanTests
```

- [ ] **Step 3: Extract `DiffPaneHunkRow` without changing legacy behavior**

Move the existing hunk header, row projection, text-segment rendering, feedback lanes, comment cards, annotations, fusion shape, and hunk actions into a focused `DiffPaneHunkRow: View`. Keep expanded collapsed-row IDs and active-thread ID in `DiffPanePresentationState`; expose methods that mutate those values so mounted views capture one stable reference object.

Define the token from plain render values:

```swift
struct DiffPaneHunkRowToken: Equatable {
    let groupID: String
    let rowsSignature: DiffDisplayRowsSignature
    let fusion: DiffPaneHunkFusionState
    let layoutMode: DiffLayoutMode
    let wrapLines: Bool
    let showWhitespace: Bool
    let codeFontFamily: String
    let codeFontSize: CGFloat
    let threadSignatures: [DiffInlineCommentThread]
    let annotations: [DiffInlineAnnotation]
    let activeHighlight: DiffReviewCommentHighlight?
    let actionPresence: DiffPaneHunkActionPresence
}

struct DiffPaneHunkActionPresence: Equatable {
    let canStage: Bool
    let canDiscard: Bool
    let canDropFromCommit: Bool
}
```

- [ ] **Step 4: Make the legacy stacks consume the extracted row view**

Replace both `lazyRowsStack` and `staticRowsStack` hunk bodies with `DiffPaneHunkRow` while retaining their current `ScrollView`, `LazyVStack`, padding, toolbar, and height-estimation behavior. Add an existing-view regression test for hunk actions and collapsed-context expansion.

- [ ] **Step 5: Run focused legacy and plan tests, then commit**

```bash
rtk xcodegen
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test -only-testing:AlasTests/DiffPaneRowPlanTests -only-testing:AlasTests/DiffPaneViewTests
git add Alas/Sources/Center/Diff/Scroller/DiffPaneRowPlan.swift Alas/Sources/Center/Diff/DiffPaneView.swift AlasTests/Center/Diff/Scroller/DiffPaneRowPlanTests.swift AlasTests/DiffPaneViewTests.swift Alas.xcodeproj/project.pbxproj
git commit -m "refactor(diff): extract reusable hunk rows"
```

### Task 7: Feature-Flagged Standalone Diff Scroller

**Files:**
- Modify: `Alas/Sources/Center/Diff/DiffPaneView.swift`
- Create: `AlasTests/Center/Diff/Scroller/DiffPaneAppKitScrollerTests.swift`

**Interfaces:**
- Consumes: Task 1 flag, Task 5 representable, and Task 6 plan builder.
- Produces: `DiffPaneView.usesAppKitScroller(flagEnabled:verticalScrollMode:)` test seam.

- [ ] **Step 1: Write failing switch tests**

```swift
@Test("only internally scrolling panes switch to AppKit")
func switchContract() {
    #expect(DiffPaneView.usesAppKitScroller(flagEnabled: true, verticalScrollMode: .internalScroll))
    #expect(!DiffPaneView.usesAppKitScroller(flagEnabled: false, verticalScrollMode: .internalScroll))
    #expect(!DiffPaneView.usesAppKitScroller(flagEnabled: true, verticalScrollMode: .staticHeight))
}
```

- [ ] **Step 2: Run and confirm the missing seam fails**

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test -only-testing:AlasTests/DiffPaneAppKitScrollerTests
```

- [ ] **Step 3: Add the runtime switch**

Cache `AppKitDiffScrollerFlag.isEnabled` in `@State`, choose `AppKitDiffScroller(plan:scrollRequest:nil:onActiveOwnerChange:)` only for `.internalScroll`, apply `.id(appKitScrollerEnabled)`, observe the override notification, and recreate `DiffPanePresentationState` when the flag changes. Leave `.staticHeight` on the extracted non-scrolling legacy composition.

- [ ] **Step 4: Add AppKit integration cases**

Mount an internally scrolling pane in a window and verify hunk action markers, line selection, context expansion, split/stacked changes, wrap/whitespace changes, text selection, and bounded host count. Confirm a flag notification rebuilds the scroller and retains model/binding values.

- [ ] **Step 5: Run and commit**

```bash
rtk xcodegen
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test -only-testing:AlasTests/DiffPaneAppKitScrollerTests -only-testing:AlasTests/DiffPaneViewTests
git add Alas/Sources/Center/Diff/DiffPaneView.swift AlasTests/Center/Diff/Scroller/DiffPaneAppKitScrollerTests.swift Alas.xcodeproj/project.pbxproj
git commit -m "feat(diff): use AppKit scrolling in standalone panes"
```

### Task 8: Review Presentation State Store

**Files:**
- Create: `Alas/Sources/Center/DiffReview/AppKitDiffReviewPresentationState.swift`
- Create: `AlasTests/Center/DiffReview/AppKitDiffReviewPresentationStateTests.swift`
- Modify: `Alas/Sources/Center/DiffReview/DiffReviewFileSection.swift`
- Modify: `Alas.xcodeproj/project.pbxproj` via XcodeGen

**Interfaces:**
- Produces: `AppKitDiffReviewPresentationStore`, `AppKitDiffReviewFileState`, and `AppKitDiffReviewActionRelay`.
- The state object owns every durable mutable property currently declared on `DiffReviewFileSection`; the row-local `@FocusState` binding remains in SwiftUI, mirrors `state.isDraftComposerFocused`, and pins its row while true. The legacy section accepts an optional injected state and otherwise creates its own.

- [ ] **Step 1: Write failing retention/reset tests**

Test that repeated `state(for:)` calls return the same object, pruning removes absent file IDs, unmount simulation does not clear drafts or expanded context, a changed render-budget reset signal clears `showFullDiffOverride`, a changed file/context signature resets context state, and a stale async generation cannot publish.

```swift
let store = AppKitDiffReviewPresentationStore()
let state = store.state(for: file)
state.pendingDraftBody = "keep me"
#expect(store.state(for: file) === state)
store.prune(keeping: [file.id])
#expect(store.state(for: file).pendingDraftBody == "keep me")
```

- [ ] **Step 2: Run and confirm failure**

```bash
rtk xcodegen
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test -only-testing:AlasTests/AppKitDiffReviewPresentationStateTests
```

- [ ] **Step 3: Move state ownership without changing rendering**

Move pending draft, focus generation, expanded IDs, context snapshot/expansion/task/error/generation, image state, hovered/active IDs, render override, copy feedback, and render-context cache into `AppKitDiffReviewFileState`. Replace direct `@State` access in `DiffReviewFileSection` with the injected observable object.

Keep these exact reset entry points on the state object:

```swift
func synchronize(file: DiffReviewFileSectionModel, contextSignature: DiffReviewContextStateSignature)
func resetForFileIdentityChange()
func resetForRenderBudgetChange()
func resetContextState()
func acceptsContextResult(fileID: DiffReviewFileID, generation: Int) -> Bool
```

- [ ] **Step 4: Add the live action relay**

Store all review action structs and callbacks in a reference relay updated before plan reconciliation. Hosted row views invoke relay methods rather than capturing an older closure generation. Add a test that an already-created row invokes the second callback after `relay.update(...)`.

- [ ] **Step 5: Run state and legacy section tests, then commit**

```bash
rtk xcodegen
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test -only-testing:AlasTests/AppKitDiffReviewPresentationStateTests -only-testing:AlasTests/DiffReviewSurfaceTests -only-testing:AlasTests/DiffReviewImageStateTests
git add Alas/Sources/Center/DiffReview/AppKitDiffReviewPresentationState.swift Alas/Sources/Center/DiffReview/DiffReviewFileSection.swift AlasTests/Center/DiffReview/AppKitDiffReviewPresentationStateTests.swift Alas.xcodeproj/project.pbxproj
git commit -m "refactor(review): retain recyclable file state"
```

### Task 9: Flattened Review Row Plan

**Files:**
- Create: `Alas/Sources/Center/DiffReview/AppKitDiffReviewRowPlan.swift`
- Create: `AlasTests/Center/DiffReview/AppKitDiffReviewRowPlanTests.swift`
- Modify: `Alas/Sources/Center/DiffReview/DiffReviewFileSection.swift`
- Modify: `Alas/Sources/Center/DiffReview/DiffReviewRenderContext.swift`
- Modify: `Alas.xcodeproj/project.pbxproj` via XcodeGen

**Interfaces:**
- Consumes: review render context, Task 6 `DiffPaneHunkRow`, and Task 8 state/relay.
- Produces: `AppKitDiffReviewRowID`, `AppKitDiffReviewRowToken`, `AppKitDiffReviewRowInput`, `AppKitDiffReviewRowPlan`, and `AppKitDiffReviewRowPlanBuilder.build(...) -> AppKitDiffReviewRowPlan`.
- `AppKitDiffReviewRowPlan` wraps `corePlan: AppKitDiffRowPlan`, `fallbackByTargetID: [String: String]`, `headerByFileID: [DiffReviewFileID: String]`, and `placeholderByFileID: [DiffReviewFileID: String]`.

- [ ] **Step 1: Write failing row-plan tests**

Build fixtures for text, image, placeholder, per-file-budget deferred, and aggregate-budget deferred files. Assert:

- all row IDs are unique and stable
- every row has the owning file's raw ID
- normal text emits header, file-level accessories, group/hunk, segment/block, and spacing rows
- image files emit header, feedback, and image rows but no text hunks
- deferred files emit header plus placeholder and map draft/feedback targets to that placeholder
- commanded draft and feedback IDs are direct row IDs when rendered
- focused composer rows use `.pinned`; ordinary text rows use `.recyclable`

- [ ] **Step 2: Run and confirm missing-builder failure**

```bash
rtk xcodegen
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test -only-testing:AlasTests/AppKitDiffReviewRowPlanTests
```

- [ ] **Step 3: Extract focused non-scrolling row views**

Turn the current private header, placeholder, image, file-level feedback, group header, accessory segment, draft card/composer, comment card, and annotation bodies into internal focused views that accept `AppKitDiffReviewFileState` and `AppKitDiffReviewActionRelay`. Make the legacy `DiffReviewFileSection` compose those same views so visuals and accessibility markers remain single-sourced.

- [ ] **Step 4: Implement stable row IDs and tokens**

Use these prefixes and existing target helpers:

```swift
file:<fileID>:header
file:<fileID>:placeholder
file:<fileID>:image
file:<fileID>:group:<groupID>:header
file:<fileID>:segment:<segmentID>:rows:<blockID>
DiffReviewInlineFeedbackTargetID.targetID(feedbackID:fileID:)
DiffReviewDraftCommentTargetID.targetID(commentID:fileID:)
file:<fileID>:composer:<segmentID>
file:<fileID>:spacing
```

Tokens include render-content hashes/signatures, plain display preferences, availability snapshots, focus/hover state, and action presence; they exclude closure identity because the relay is live.

- [ ] **Step 5: Implement the flattened plan builder**

Apply `DiffReviewRenderEligibility.renderRows` before iterating files. Derive each file's render context once from its state cache, append rows in the existing visual order, and set estimated heights from existing estimators or focused per-row constants. Populate `fallbackByTargetID`, `headerByFileID`, and `placeholderByFileID` rather than emitting zero-height SwiftUI `.id` anchors.

- [ ] **Step 6: Run plan and legacy rendering tests, then commit**

```bash
rtk xcodegen
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test -only-testing:AlasTests/AppKitDiffReviewRowPlanTests -only-testing:AlasTests/DiffReviewSurfaceTests -only-testing:AlasTests/DiffReviewInlineFeedbackMarkdownTests
git add Alas/Sources/Center/DiffReview/AppKitDiffReviewRowPlan.swift Alas/Sources/Center/DiffReview/DiffReviewFileSection.swift Alas/Sources/Center/DiffReview/DiffReviewRenderContext.swift AlasTests/Center/DiffReview/AppKitDiffReviewRowPlanTests.swift Alas.xcodeproj/project.pbxproj
git commit -m "feat(review): build flattened AppKit row plans"
```

### Task 10: AppKit Multi-File Review Stream And Navigation

**Files:**
- Create: `Alas/Sources/Center/DiffReview/AppKitDiffReviewScroller.swift`
- Create: `AlasTests/Center/DiffReview/AppKitDiffReviewScrollerTests.swift`
- Modify: `Alas/Sources/Center/DiffReview/DiffReviewSurface.swift`
- Modify: `Alas/Sources/Center/DiffReview/DiffReviewScrollSpy.swift`
- Modify: `AlasTests/DiffReviewSurfaceTests.swift`
- Modify: `AlasTests/DiffReviewScrollSpyTests.swift`
- Modify: `Alas.xcodeproj/project.pbxproj` via XcodeGen

**Interfaces:**
- Consumes: Task 9 plan and all three existing scroll-command types.
- Produces: `AppKitDiffReviewScroller`, `AppKitDiffReviewScrollRequestResolver`, and `DiffReviewSurface.usesAppKitScroller(flagEnabled:)`.

- [ ] **Step 1: Write failing switch and command-resolution tests**

```swift
#expect(DiffReviewSurface.usesAppKitScroller(flagEnabled: true))
#expect(!DiffReviewSurface.usesAppKitScroller(flagEnabled: false))

let request = AppKitDiffReviewScrollRequestResolver.request(
    fileCommand: nil,
    inlineFeedbackCommand: feedbackCommand,
    draftCommentCommand: nil,
    plan: deferredPlan
)
#expect(request?.targetID == deferredPlan.placeholderByFileID[fileID])
#expect(request?.alignment == .center)
```

Also assert file commands align top, feedback/draft commands align center, generations remain distinct, same-file commands do not require a two-phase realization delay, and missing targets fall back to the file header.

- [ ] **Step 2: Run and confirm failure**

```bash
rtk xcodegen
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test -only-testing:AlasTests/AppKitDiffReviewScrollerTests
```

- [ ] **Step 3: Implement the review adapter**

`AppKitDiffReviewScroller` builds/receives the flattened plan, resolves the latest command into one core `AppKitDiffScrollRequest`, converts active owner raw values back to `DiffReviewFileID`, and updates the existing selection/programmatic-scroll state through closures. No `Task.sleep` or two-phase scroll is used on the AppKit path because target rows are direct tiling entries.

- [ ] **Step 4: Add the central-stream switch**

Rename the existing implementation `legacyMainReviewStream`. Cache the flag in `DiffReviewSurface`, choose the AppKit adapter when enabled, apply `.id(appKitScrollerEnabled)`, observe the flag notification, clear only scroll-command bookkeeping, and prune presentation state when the file set changes. Keep both side rails outside the switch.

- [ ] **Step 5: Add window-level behavior tests**

Cover rail-to-file scrolling, active-file selection from native viewport changes, same-file and cross-file feedback navigation, deferred-placeholder fallback, selection suppression during animated programmatic scroll, comment insertion above the viewport, context expansion above the viewport, focused composer pinning, image load/retry, staged actions, preference changes, session replacement, and runtime toggle scroll reset.

- [ ] **Step 6: Run the shared review suites and commit**

```bash
rtk xcodegen
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test -only-testing:AlasTests/AppKitDiffReviewScrollerTests -only-testing:AlasTests/DiffReviewSurfaceTests -only-testing:AlasTests/DiffReviewScrollSpyTests -only-testing:AlasTests/DiffReviewImageStateTests -only-testing:AlasTests/DiffReviewStagedMutationActionsTests
git add Alas/Sources/Center/DiffReview/AppKitDiffReviewScroller.swift Alas/Sources/Center/DiffReview/DiffReviewSurface.swift Alas/Sources/Center/DiffReview/DiffReviewScrollSpy.swift AlasTests/Center/DiffReview/AppKitDiffReviewScrollerTests.swift AlasTests/DiffReviewSurfaceTests.swift AlasTests/DiffReviewScrollSpyTests.swift Alas.xcodeproj/project.pbxproj
git commit -m "feat(review): scroll multi-file diffs with AppKit"
```

### Task 11: GG Split Preview Adapter

**Files:**
- Create: `Alas/Sources/Integrations/GG/GGSplitPreviewRowPlan.swift`
- Create: `AlasTests/Integrations/GG/GGSplitPreviewRowPlanTests.swift`
- Modify: `Alas/Sources/Integrations/GG/GGSplitCommitTabView.swift`
- Modify: `Alas.xcodeproj/project.pbxproj` via XcodeGen

**Interfaces:**
- Consumes: Task 5 scroller and Task 6 diff hunk plan factory.
- Produces: `GGSplitPreviewRowPlanBuilder`, `GGSplitPreviewImageStore`, and `GGSplitCommitTabView.usesAppKitPreviewScroller(flagEnabled:)`.

- [ ] **Step 1: Write failing partition and row-order tests**

Given two text files, one resulting image, and one non-textual file, assert the plan order is file header/hunks, file header/hunks, image, other-file. Assert unique IDs include the preview side/title so the two side-by-side preview panes cannot collide. Assert image state survives repeated plan builds and prunes removed paths.

- [ ] **Step 2: Run and confirm failure**

```bash
rtk xcodegen
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test -only-testing:AlasTests/GGSplitPreviewRowPlanTests
```

- [ ] **Step 3: Implement the plan and image store**

Move `GGSplitResultingImagePreview.imageSide` into a store keyed by worktree path, revision, and relative path. Build text rows with the shared `DiffPaneRowPlanBuilder`, retaining the current path header before each file. Keep image height 220 points and preserve the current spinner/failure rendering.

- [ ] **Step 4: Switch only the preview scroll subtree**

Keep the preview title/header, empty state, split form, and action bar unchanged. Cache and observe `AppKitDiffScrollerFlag`; use the AppKit plan when enabled and the existing `ScrollView`/`LazyVStack` when disabled. Rebuilding after a flag change resets only preview scroll positions.

- [ ] **Step 5: Run split-preview and existing GG tests, then commit**

```bash
rtk xcodegen
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test -only-testing:AlasTests/GGSplitPreviewRowPlanTests -only-testing:AlasTests/GGSplitCommitModelTests
git add Alas/Sources/Integrations/GG/GGSplitPreviewRowPlan.swift Alas/Sources/Integrations/GG/GGSplitCommitTabView.swift AlasTests/Integrations/GG/GGSplitPreviewRowPlanTests.swift Alas.xcodeproj/project.pbxproj
git commit -m "feat(gg): use AppKit split preview scrolling"
```

### Task 12: Stress Coverage, Accessibility, And Final Verification

**Files:**
- Create: `AlasTests/Center/Diff/Scroller/AppKitDiffScrollerStressTests.swift`
- Modify: AppKit scroller/review files only if the stress or accessibility tests expose a concrete defect
- Modify: `Alas.xcodeproj/project.pbxproj` via XcodeGen

**Interfaces:**
- Consumes: completed engine and all adapters.
- Produces: deterministic regression evidence and final build/test proof; no new product API.

- [ ] **Step 1: Add a deterministic 20,000-row stress test**

Build a plan with 20,000 fixed-height rows across 250 owners. Mount it in a 1200×800 window, scroll to the middle and end, update rows above and below the viewport, and assert:

```swift
#expect(pool.mountedIDs.count < 120)
#expect(abs(anchorScreenYBefore - anchorScreenYAfter) < 0.5)
#expect(reconciler.fullPlanApplyCountForTests == 2)
```

Do not assert elapsed time.

- [ ] **Step 2: Add accessibility and first-responder tests**

For review and standalone hosts, confirm existing accessibility identifiers can be found through hosted rows, keyboard focus enters a draft composer, the focused row remains mounted while scrolled away, draft text survives, and releasing focus permits recycling.

- [ ] **Step 3: Run all focused suites**

```bash
rtk xcodegen
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test \
  -only-testing:AlasTests/AppKitDiffScrollerFlagTests \
  -only-testing:AlasTests/AppKitDiffTilingControllerTests \
  -only-testing:AlasTests/AppKitDiffRowHostingPoolTests \
  -only-testing:AlasTests/AppKitDiffScrollerReconcilerTests \
  -only-testing:AlasTests/AppKitDiffScrollerTests \
  -only-testing:AlasTests/DiffPaneRowPlanTests \
  -only-testing:AlasTests/DiffPaneAppKitScrollerTests \
  -only-testing:AlasTests/AppKitDiffReviewPresentationStateTests \
  -only-testing:AlasTests/AppKitDiffReviewRowPlanTests \
  -only-testing:AlasTests/AppKitDiffReviewScrollerTests \
  -only-testing:AlasTests/GGSplitPreviewRowPlanTests \
  -only-testing:AlasTests/AppKitDiffScrollerStressTests \
  -only-testing:AlasTests/DiffPaneViewTests \
  -only-testing:AlasTests/DiffReviewSurfaceTests
```

Expected: all focused suites pass.

- [ ] **Step 4: Run formatting, build, and full tests**

```bash
swiftformat Alas AlasTests --lint
git diff --check
rtk xcodegen
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test
```

Expected: lint and whitespace checks pass, the app builds, and the full suite passes. If the full suite exposes an unrelated pre-existing failure, rerun it in isolation and report it separately rather than attributing it to this change.

- [ ] **Step 5: Profile both implementations manually**

Use the same synthetic large review and one real large review. Capture a Time Profiler or `sample` trace while continuously scrolling with the flag off and on. The AppKit path must show no outer diff/review `LazyVStack`, `LazySubviewPlacements`, or `ForEachState` scroll-layout stack; scrolling must remain responsive without visible offset jumps or a beachball.

- [ ] **Step 6: Commit stress coverage and any verified fixes**

```bash
git add AlasTests/Center/Diff/Scroller/AppKitDiffScrollerStressTests.swift Alas.xcodeproj/project.pbxproj
git add Alas/Sources/Center/Diff/Scroller/AppKitDiffScrollerReconciler.swift Alas/Sources/Center/Diff/Scroller/AppKitDiffScroller.swift Alas/Sources/Center/DiffReview/AppKitDiffReviewScroller.swift Alas/Sources/Center/DiffReview/AppKitDiffReviewRowPlan.swift
git commit -m "test(diff): cover AppKit scroller stress cases"
```

Before committing, confirm `git diff --cached --stat` contains only stress coverage and concrete fixes required by this task; do not sweep unrelated user changes into the commit.
