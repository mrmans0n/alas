# ACP Compact Task Control Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the ACP chat's responsive right-side task sidebar with one compact, animated task control in the existing top toolbar.

**Architecture:** Remove the sidebar presentation mode and all runtime state that switches between sidebar and toolbar, leaving `ACPTabView` as a single chat column. Keep `ACPPlanPillState` as the pure plan-to-presentation adapter, extend it with testable display and accessibility strings plus reduced-motion policy, and render the result through a compact `ACPPlanPill` that opens the existing checklist popover.

**Tech Stack:** Swift 5.9+, SwiftUI for macOS, Swift Testing (`import Testing`), XcodeGen.

## Global Constraints

- Keep code, comments, logs, and UI strings in English.
- Use Swift Testing (`import Testing`), not XCTest.
- Do not add dependencies or change persisted ACP plan data.
- The task control remains inline with the session, MCP, recovery, and goal controls; it is not independently centered.
- The control is 24pt high with 5pt continuous corners and displays `Tasks`, completed/total count, and the current step.
- The current-step text is single-line, capped at 220pt, and truncates at the tail.
- The moving outline runs only while an item is `in_progress`; Reduce Motion uses a static active outline.
- The click popover continues to show `ACPPlanChecklist` at 320pt width.
- Do not add agent attribution to code, commits, or documentation.

---

### Task 1: Remove The Responsive Task Sidebar

**Files:**
- Modify: `Alas/Sources/ACP/UI/ACPTabView.swift`
- Modify: `Alas/Sources/ACP/UI/ACPToolbar.swift`
- Modify: `Alas/Sources/ACP/UI/ACPPlanPill.swift`
- Modify: `Alas/Sources/ACP/UI/ACPPlanChecklist.swift`
- Modify: `Alas/Sources/ACP/UI/ACPChatLayout.swift`
- Modify: `Alas/Sources/ACP/Session/ACPSession.swift`
- Modify: `Alas/Sources/ACP/Session/ACPSessionManager.swift`
- Modify: `AlasTests/ACP/UI/ACPChatLayoutTests.swift`
- Delete: `Alas/Sources/ACP/UI/ACPPlanSidebar.swift`
- Delete: `Alas/Sources/ACP/UI/ACPPlanSidebarVisibility.swift`
- Delete: `AlasTests/ACP/UI/ACPPlanSidebarVisibilityTests.swift`
- Delete: `AlasTests/ACP/Session/ACPSessionManagerPlanSidebarLayoutTests.swift`

**Interfaces:**
- Consumes: `ACPChatLayout.contentMaxWidth(forChatColumnWidth:)`, `ACPPlanPill(transcript:)`, and `ACPPlanChecklist(items:)`.
- Produces: A single-column `ACPSessionView` with no sidebar/minimize/restore state; `ACPToolbar` owns a plain `ACPPlanPill(transcript:)`.

- [ ] **Step 1: Update the layout test to describe a permanently full-width chat column**

Replace `ACPChatLayoutTests` with coverage for only the content-width behavior that remains:

```swift
import Testing
@testable import Alas

@Suite("ACP chat layout")
struct ACPChatLayoutTests {
    @Test func keepsCurrentWidthForNormalPanes() {
        #expect(ACPChatLayout.contentMaxWidth(forPaneWidth: 900) == 720)
        #expect(ACPChatLayout.contentMaxWidth(forPaneWidth: 1_080) == 720)
    }

    @Test func growsOnWidePanes() {
        let width = ACPChatLayout.contentMaxWidth(forPaneWidth: 1_200)

        #expect(width > 720)
        #expect(width < 960)
    }

    @Test func capsOnUltrawidePanes() {
        #expect(ACPChatLayout.contentMaxWidth(forPaneWidth: 1_600) == 960)
        #expect(ACPChatLayout.contentMaxWidth(forPaneWidth: 3_000) == 960)
    }

    @Test func contentWidthUsesMeasuredChatColumnWidth() {
        #expect(ACPChatLayout.contentMaxWidth(forChatColumnWidth: 1_200) == 840)
        #expect(ACPChatLayout.contentMaxWidth(forChatColumnWidth: 880) == 720)
    }
}
```

- [ ] **Step 2: Remove sidebar-only source and test files**

Delete:

```text
Alas/Sources/ACP/UI/ACPPlanSidebar.swift
Alas/Sources/ACP/UI/ACPPlanSidebarVisibility.swift
AlasTests/ACP/UI/ACPPlanSidebarVisibilityTests.swift
AlasTests/ACP/Session/ACPSessionManagerPlanSidebarLayoutTests.swift
```

- [ ] **Step 3: Remove sidebar state and restore one-column chat layout**

In `ACPSessionView`, remove:

```swift
@State private var showPlanSidebar: Bool = false
@State private var suppressRestoredPlanSidebarPlanChange: Bool = false
```

Remove `updatePlanSidebar(paneWidth:)`, `restoreOrInitializePlanSidebar(paneWidth:)`, the outer sidebar-decision `GeometryReader`, `.environment(\.acpPlanSidebarVisible, ...)`, and all sidebar-related `.onAppear` / `.onChange` hooks.

The body becomes:

```swift
var body: some View {
    VStack(spacing: 0) {
        if ACPFirstRunConnectingPolicy.showsChrome(firstRunConnecting: isFirstRunConnecting) {
            ACPToolbar(
                session: session,
                manager: manager,
                agentLookup: { state.agent(id: $0) },
                state: state,
                worktree: worktree
            )
            adapterBanner()
            contextRestoreBanner()
            if isMirror {
                mirrorBanner()
            }
            if let err = session.lastError {
                errorBanner(err)
            }
            if case .failed(let msg) = session.hydrationState {
                hydrationFailureBanner(message: msg)
            }
        }
        transcriptAndComposer
    }
    .onChange(of: isFirstRunConnecting) { oldValue, newValue in
        composerFocusRequest = ACPComposerFocusPolicy.focusRequest(
            current: composerFocusRequest,
            oldFirstRunConnecting: oldValue,
            newFirstRunConnecting: newValue,
            composerReady: composerCanAcceptInput
        )
    }
    .task(id: sessionId) {
        await hydrateAndAttach()
    }
    .onExitCommand {
        handleEscape()
    }
}
```

Replace `transcriptAndComposer`'s sidebar `HStack` with the measured chat surface only:

```swift
private var transcriptAndComposer: some View {
    GeometryReader { chatProxy in
        let chatContentMaxWidth = ACPChatLayout.contentMaxWidth(
            forChatColumnWidth: chatProxy.size.width
        )
        chatSurface(contentMaxWidth: chatContentMaxWidth)
            .frame(width: chatProxy.size.width, height: chatProxy.size.height)
            .animation(emptyStateAnimation, value: isNewEmptySession)
            .animation(emptyStateAnimation, value: isFirstRunConnecting)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
}
```

- [ ] **Step 4: Remove sidebar-only parameters and runtime memory**

Change `ACPToolbar` by deleting:

```swift
let planSidebarUserMinimized: Bool
let onRestorePlanSidebar: () -> Void
```

Construct the task control as:

```swift
ACPPlanPill(transcript: session.transcript)
    .layoutPriority(1)
```

Delete `ACPSession.planSidebarMinimized`, `ACPSessionManager.planSidebarVisibility`, `rememberedPlanSidebarVisibility(for:)`, and `rememberPlanSidebarVisibility(_:for:)`. Remove any cleanup calls for `planSidebarVisibility` from manager close, delete, or disposal paths.

Remove `ACPPlanSidebarVisibleKey`, `EnvironmentValues.acpPlanSidebarVisible`, `sidebarUserMinimized`, restore mode, `onRestoreSidebar`, and sidebar-gating branches from `ACPPlanPill`. Its body gate becomes:

```swift
Group {
    if let state = ACPPlanPillState(items: transcript.currentPlan) {
        pill(state: state)
    }
}
```

Remove `onMinimize` and the minus button from `ACPPlanChecklist`; its public input becomes:

```swift
let items: [ACPMessage.PlanItem]
```

- [ ] **Step 5: Remove the sidebar branch from `ACPChatLayout`**

Delete:

```swift
static let planSidebarWidth: CGFloat = 320

static func chatColumnWidth(
    forPaneWidth paneWidth: CGFloat,
    planSidebarVisible: Bool
) -> CGFloat {
    guard planSidebarVisible else {
        return paneWidth
    }
    return max(0, paneWidth - planSidebarWidth)
}
```

Keep `contentMaxWidth(forChatColumnWidth:)` and `contentMaxWidth(forPaneWidth:)` unchanged.

- [ ] **Step 6: Regenerate the project and run focused verification**

Run:

```bash
xcodegen
ALAS_FFF_TARGET_ARCH=arm64 xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test \
  -only-testing:AlasTests/ACPChatLayoutTests \
  -only-testing:AlasTests/ACPPlanPillStateTests
```

Expected: XcodeGen succeeds; the selected tests pass; no source or project-file reference remains for `ACPPlanSidebar`, `ACPPlanSidebarVisibility`, `planSidebarMinimized`, or remembered plan-sidebar visibility.

- [ ] **Step 7: Commit**

```bash
git add Alas.xcodeproj/project.pbxproj Alas/Sources/ACP AlasTests/ACP
git commit -m "refactor(acp): remove task sidebar"
```

### Task 2: Build The Compact Animated Task Control

**Files:**
- Modify: `Alas/Sources/ACP/UI/ACPPlanPillState.swift`
- Modify: `Alas/Sources/ACP/UI/ACPPlanPill.swift`
- Modify: `AlasTests/ACP/UI/ACPPlanPillStateTests.swift`

**Interfaces:**
- Consumes: `ACPPlanPillState(items:)`, `ACPTranscript.currentPlan`, `ACPPlanChecklist(items:)`, `EnvironmentValues.accessibilityReduceMotion`.
- Produces: `ACPPlanPillState.progressText: String`, `ACPPlanPillState.accessibilityLabel: String`, and `ACPPlanPillState.outlineIsAnimated(reduceMotion: Bool) -> Bool`; a 24pt compact task button with a 220pt-capped current-step label and popover.

- [ ] **Step 1: Write failing presentation-policy tests**

Append:

```swift
@Test("display strings keep compact and accessibility copy distinct")
func displayStrings() {
    let state = ACPPlanPillState(items: [
        .init(content: "Read code", status: "completed"),
        .init(content: "Implement toolbar control", status: "in_progress"),
        .init(content: "Test", status: "pending")
    ])

    #expect(state?.progressText == "1/3")
    #expect(state?.accessibilityLabel
        == "Tasks, 1 of 3 complete, Implement toolbar control")
}

@Test("outline animation respects activity and Reduce Motion")
func outlineAnimationPolicy() {
    let active = ACPPlanPillState(items: [
        .init(content: "Implement", status: "in_progress")
    ])
    let pending = ACPPlanPillState(items: [
        .init(content: "Implement", status: "pending")
    ])

    #expect(active?.outlineIsAnimated(reduceMotion: false) == true)
    #expect(active?.outlineIsAnimated(reduceMotion: true) == false)
    #expect(pending?.outlineIsAnimated(reduceMotion: false) == false)
}

@Test("unknown status keeps fallback title without animation")
func unknownStatusFallback() {
    let state = ACPPlanPillState(items: [
        .init(content: "Agent-defined state", status: "blocked")
    ])

    #expect(state?.currentStep == "Agent-defined state")
    #expect(state?.isAnimating == false)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:

```bash
ALAS_FFF_TARGET_ARCH=arm64 xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test \
  -only-testing:AlasTests/ACPPlanPillStateTests
```

Expected: compilation fails because `progressText`, `accessibilityLabel`, and `outlineIsAnimated(reduceMotion:)` do not exist.

- [ ] **Step 3: Add the pure presentation policy**

Add to `ACPPlanPillState`:

```swift
var progressText: String {
    "\(done)/\(total)"
}

var accessibilityLabel: String {
    "Tasks, \(done) of \(total) complete, \(currentStep)"
}

func outlineIsAnimated(reduceMotion: Bool) -> Bool {
    isAnimating && !reduceMotion
}
```

- [ ] **Step 4: Rebuild `ACPPlanPill` as the compact toolbar control**

Add:

```swift
@Environment(\.accessibilityReduceMotion) private var reduceMotion
```

The button label becomes:

```swift
HStack(spacing: 5) {
    Text("Tasks")
        .font(.system(size: 10.5, weight: .semibold))
    Text(state.progressText)
        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
    Text("·")
        .font(.system(size: 10.5, weight: .semibold))
        .foregroundStyle(theme.color("fg-faint"))
    Text(state.currentStep)
        .font(.system(size: 10.5, weight: .medium))
        .foregroundStyle(theme.color("fg"))
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(maxWidth: 220, alignment: .leading)
}
.foregroundStyle(theme.color("accent"))
.padding(.horizontal, 8)
.frame(height: 24)
.background(theme.color("accent").opacity(0.10))
.clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
.overlay {
    taskOutline(state: state)
}
```

Attach:

```swift
.help(state.accessibilityLabel)
.accessibilityLabel(state.accessibilityLabel)
.popover(isPresented: $popoverOpen, arrowEdge: .top) {
    if let items = transcript.currentPlan, !items.isEmpty {
        ACPPlanChecklist(items: items)
            .frame(width: 320)
    }
}
```

Remove the old progress bar, accessory icon, status dot, gradient pill background, 12pt corner radius, and shadow.

- [ ] **Step 5: Implement the continuous traveling outline**

Use a static base stroke in all states and an angular-gradient trail only when motion is allowed:

```swift
@ViewBuilder
private func taskOutline(state: ACPPlanPillState) -> some View {
    let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
    shape
        .strokeBorder(
            theme.color("accent").opacity(state.isAnimating ? 0.48 : 0.28),
            lineWidth: state.isAnimating ? 0.75 : 0.5
        )

    if state.outlineIsAnimated(reduceMotion: reduceMotion) {
        TimelineView(.animation) { context in
            let cycleSeconds = 1.8
            let phase = context.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: cycleSeconds) / cycleSeconds
            shape
                .strokeBorder(travelingGradient(phase: phase), lineWidth: 1.25)
        }
    }
}

private func travelingGradient(phase: Double) -> AngularGradient {
    let start = Angle.degrees(phase * 360)
    return AngularGradient(
        stops: [
            .init(color: .clear, location: 0.00),
            .init(color: .clear, location: 0.72),
            .init(color: theme.color("accent").opacity(0.20), location: 0.80),
            .init(color: theme.color("accent").opacity(0.65), location: 0.90),
            .init(color: theme.color("accent"), location: 0.97),
            .init(color: .clear, location: 1.00)
        ],
        center: .center,
        startAngle: start,
        endAngle: start + .degrees(360)
    )
}
```

The active Reduce Motion state keeps the brighter static base stroke but never creates the `TimelineView`.

- [ ] **Step 6: Run focused tests and inspect the diff**

Run:

```bash
ALAS_FFF_TARGET_ARCH=arm64 xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test \
  -only-testing:AlasTests/ACPPlanPillStateTests \
  -only-testing:AlasTests/ACPChatLayoutTests
git diff --check
```

Expected: selected tests pass and `git diff --check` reports no errors.

- [ ] **Step 7: Commit**

```bash
git add Alas/Sources/ACP/UI/ACPPlanPill.swift Alas/Sources/ACP/UI/ACPPlanPillState.swift AlasTests/ACP/UI/ACPPlanPillStateTests.swift
git commit -m "feat(acp): compact task toolbar control"
```

### Task 3: Verify The Complete Change

**Files:**
- Modify only if verification reveals a defect in files changed by Tasks 1-2.

**Interfaces:**
- Consumes: The single-column ACP chat and compact task control delivered by Tasks 1-2.
- Produces: Verified project generation, focused tests, quiet build, and full test-suite evidence.

- [ ] **Step 1: Confirm obsolete symbols and files are gone**

Run:

```bash
rg -n "ACPPlanSidebar|ACPPlanSidebarVisibility|planSidebarMinimized|rememberPlanSidebarVisibility|rememberedPlanSidebarVisibility|planSidebarWidth" Alas AlasTests
```

Expected: no matches.

- [ ] **Step 2: Regenerate the project**

Run:

```bash
xcodegen
git diff --check
```

Expected: XcodeGen succeeds and the diff check reports no errors.

- [ ] **Step 3: Run focused ACP tests**

Run:

```bash
ALAS_FFF_TARGET_ARCH=arm64 xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test \
  -only-testing:AlasTests/ACPPlanPillStateTests \
  -only-testing:AlasTests/ACPChatLayoutTests
```

Expected: all selected tests pass.

- [ ] **Step 4: Run the quiet project build**

Run:

```bash
ALAS_FFF_TARGET_ARCH=arm64 xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
```

Expected: build exits successfully.

- [ ] **Step 5: Run the project-required full test command**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test
```

Expected: tests pass. If the machine reproduces a known unrelated environment or AppKit failure, preserve the exact failure and separately report the focused ACP and quiet-build results.
