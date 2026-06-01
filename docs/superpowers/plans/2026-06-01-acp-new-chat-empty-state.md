# ACP New Chat Empty State Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the approved centered ACP new-chat empty state with clickable starter prompts and a smooth transition back to the existing bottom composer after the first prompt starts.

**Architecture:** Keep the feature local to the ACP UI. Add small pure helpers for the new-session visibility rule and starter prompt draft insertion, then wire those helpers into `ACPTabView`, `ACPComposer`, and `ACPInputField` without changing ACP protocol lifecycle or persistence semantics.

**Tech Stack:** Swift 5.9, SwiftUI, AppKit `NSViewRepresentable`, Swift Testing, XcodeGen.

---

## File Structure

- Create `Alas/Sources/ACP/UI/ACPNewChatEmptyStatePolicy.swift`
  - Owns the pure visibility decision for the new empty state.
- Create `Alas/Sources/ACP/UI/ACPStarterPrompt.swift`
  - Owns chip labels, inserted prompt text, and draft appending behavior.
- Create `Alas/Sources/ACP/UI/ACPNewChatEmptyStateView.swift`
  - Renders only the welcome text and starter chips. It does not own the composer.
- Modify `Alas/Sources/ACP/UI/ACPComposer.swift`
  - Adds a focus request token to `ACPInputField` so starter chips can focus the AppKit text view after inserting text.
- Modify `Alas/Sources/ACP/UI/ACPComposerShell.swift`
  - Adds a composer placement mode so the same composer can render in the current bottom position or raised new-chat position.
- Modify `Alas/Sources/ACP/UI/ACPTabView.swift`
  - Computes the new empty state, renders the welcome overlay, inserts starter prompts through existing draft persistence, and animates the composer placement change.
- Create `AlasTests/ACP/UI/ACPNewChatEmptyStateTests.swift`
  - Covers pure policy and starter prompt draft behavior.
- Regenerate `Alas.xcodeproj` with `xcodegen` after adding source and test files.

## Task 1: Add Pure Empty-State Policy

**Files:**
- Create: `Alas/Sources/ACP/UI/ACPNewChatEmptyStatePolicy.swift`
- Test: `AlasTests/ACP/UI/ACPNewChatEmptyStateTests.swift`

- [ ] **Step 1: Write the failing policy tests**

Create `AlasTests/ACP/UI/ACPNewChatEmptyStateTests.swift`:

```swift
import Foundation
import Testing
@testable import Alas

@MainActor
@Suite("ACP new chat empty state")
struct ACPNewChatEmptyStateTests {
    @Test("fresh ready empty sessions show the new empty state")
    func freshReadyEmptySessionShowsEmptyState() {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "wt", title: "New session")
        session.setupState = .ready
        session.agentState = .ready

        #expect(ACPNewChatEmptyStatePolicy.isVisible(for: session))
    }

    @Test("restored sessions do not show the new empty state")
    func restoredSessionDoesNotShowEmptyState() {
        let session = ACPSession(
            id: "s",
            agentId: "codex",
            worktreeId: "wt",
            title: "Restored",
            hydrationState: .ready,
            restoredFromPersistence: true
        )
        session.setupState = .ready
        session.agentState = .ready

        #expect(!ACPNewChatEmptyStatePolicy.isVisible(for: session))
    }

    @Test("hydrating and failed sessions do not show the new empty state")
    func unavailableSessionStatesDoNotShowEmptyState() {
        let loading = ACPSession(
            id: "loading",
            agentId: "codex",
            worktreeId: "wt",
            title: "Loading",
            hydrationState: .loading
        )
        loading.setupState = .ready
        loading.agentState = .ready

        let failed = ACPSession(
            id: "failed",
            agentId: "codex",
            worktreeId: "wt",
            title: "Failed",
            hydrationState: .failed("boom")
        )
        failed.setupState = .ready
        failed.agentState = .ready

        #expect(!ACPNewChatEmptyStatePolicy.isVisible(for: loading))
        #expect(!ACPNewChatEmptyStatePolicy.isVisible(for: failed))
    }

    @Test("setup problems, agent failures, and existing transcript suppress the new empty state")
    func blockedOrNonEmptySessionsDoNotShowEmptyState() {
        let setup = ACPSession(id: "setup", agentId: "codex", worktreeId: "wt", title: "Setup")
        setup.setupState = .needsSetup(reason: "Install Codex")
        setup.agentState = .ready

        let errored = ACPSession(id: "errored", agentId: "codex", worktreeId: "wt", title: "Errored")
        errored.setupState = .ready
        errored.agentState = .failed("boom")

        let messaged = ACPSession(id: "messaged", agentId: "codex", worktreeId: "wt", title: "Messaged")
        messaged.setupState = .ready
        messaged.agentState = .ready
        messaged.transcript.messages.append(.systemNotice(id: UUID(), text: "notice"))

        #expect(!ACPNewChatEmptyStatePolicy.isVisible(for: setup))
        #expect(!ACPNewChatEmptyStatePolicy.isVisible(for: errored))
        #expect(!ACPNewChatEmptyStatePolicy.isVisible(for: messaged))
    }

    @Test("fresh attached sessions remain empty even after receiving a remote session id")
    func remoteSessionIdDoesNotSuppressFreshEmptyState() {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "wt", title: "New session")
        session.setupState = .ready
        session.agentState = .ready
        session.remoteSessionId = "remote-id"

        #expect(ACPNewChatEmptyStatePolicy.isVisible(for: session))
    }
}
```

- [ ] **Step 2: Run the focused test and verify it fails**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test -only-testing:AlasTests/ACPNewChatEmptyStateTests
```

Expected: FAIL because `ACPNewChatEmptyStatePolicy` does not exist.

- [ ] **Step 3: Add the minimal policy implementation**

Create `Alas/Sources/ACP/UI/ACPNewChatEmptyStatePolicy.swift`:

```swift
import Foundation

@MainActor
enum ACPNewChatEmptyStatePolicy {
    static func isVisible(for session: ACPSession) -> Bool {
        guard !session.restoredFromPersistence else { return false }
        guard session.transcript.messages.isEmpty else { return false }
        guard session.hydrationState == .ready else { return false }
        guard session.lastError == nil else { return false }

        if case .ready = session.setupState {
            // continue
        } else {
            return false
        }

        if case .ready = session.agentState {
            return true
        }
        return false
    }
}
```

- [ ] **Step 4: Regenerate the Xcode project**

Run:

```bash
xcodegen
```

Expected: succeeds and updates `Alas.xcodeproj` if the file list changed.

- [ ] **Step 5: Run the focused test and verify it passes**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test -only-testing:AlasTests/ACPNewChatEmptyStateTests
```

Expected: PASS for all policy tests.

- [ ] **Step 6: Commit**

```bash
git add Alas/Sources/ACP/UI/ACPNewChatEmptyStatePolicy.swift AlasTests/ACP/UI/ACPNewChatEmptyStateTests.swift Alas.xcodeproj
git commit -m "test: cover ACP new chat empty state policy"
```

## Task 2: Add Starter Prompt Draft Behavior

**Files:**
- Create: `Alas/Sources/ACP/UI/ACPStarterPrompt.swift`
- Modify: `AlasTests/ACP/UI/ACPNewChatEmptyStateTests.swift`

- [ ] **Step 1: Add failing starter prompt tests**

Append these tests inside `ACPNewChatEmptyStateTests`:

```swift
    @Test("starter prompt replaces an empty draft")
    func starterPromptReplacesEmptyDraft() {
        let draft = ACPStarterPrompt.reviewChanges.applying(to: .empty)

        #expect(draft == ACPComposerDraft(segments: [
            .text("Review the current changes in this worktree and suggest the next steps.")
        ]))
    }

    @Test("starter prompt appends after non-empty text with a blank line")
    func starterPromptAppendsAfterExistingText() {
        let existing = ACPComposerDraft(segments: [.text("Existing note")])
        let draft = ACPStarterPrompt.planFeature.applying(to: existing)

        #expect(draft == ACPComposerDraft(segments: [
            .text("Existing note\n\n"),
            .text("Help me plan this feature. Ask clarifying questions first if the goal is ambiguous.")
        ]))
    }

    @Test("starter prompts expose stable short labels")
    func starterPromptLabelsAreStable() {
        #expect(ACPStarterPrompt.allCases.map(\.label) == [
            "Review current changes",
            "Find a bug",
            "Plan a feature",
        ])
    }
```

- [ ] **Step 2: Run the focused test and verify it fails**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test -only-testing:AlasTests/ACPNewChatEmptyStateTests
```

Expected: FAIL because `ACPStarterPrompt` does not exist.

- [ ] **Step 3: Add the starter prompt helper**

Create `Alas/Sources/ACP/UI/ACPStarterPrompt.swift`:

```swift
import Foundation

enum ACPStarterPrompt: String, CaseIterable, Identifiable {
    case reviewChanges
    case findBug
    case planFeature

    var id: String { rawValue }

    var label: String {
        switch self {
        case .reviewChanges:
            return "Review current changes"
        case .findBug:
            return "Find a bug"
        case .planFeature:
            return "Plan a feature"
        }
    }

    var promptText: String {
        switch self {
        case .reviewChanges:
            return "Review the current changes in this worktree and suggest the next steps."
        case .findBug:
            return "Look for likely bugs or fragile spots in this worktree. Start by inspecting the current changes."
        case .planFeature:
            return "Help me plan this feature. Ask clarifying questions first if the goal is ambiguous."
        }
    }

    func applying(to draft: ACPComposerDraft) -> ACPComposerDraft {
        let prompt = ACPComposerDraft(segments: [.text(promptText)])
        if draft.isEmpty { return prompt }
        return ACPComposerDraft(segments: draft.segments + [.text("\n\n")] + prompt.segments)
    }
}
```

- [ ] **Step 4: Regenerate the Xcode project**

Run:

```bash
xcodegen
```

Expected: succeeds.

- [ ] **Step 5: Run the focused test and verify it passes**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test -only-testing:AlasTests/ACPNewChatEmptyStateTests
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Alas/Sources/ACP/UI/ACPStarterPrompt.swift AlasTests/ACP/UI/ACPNewChatEmptyStateTests.swift Alas.xcodeproj
git commit -m "feat: add ACP starter prompt drafts"
```

## Task 3: Add Focus Request Plumbing to the Composer

**Files:**
- Modify: `Alas/Sources/ACP/UI/ACPComposer.swift`
- Modify: `Alas/Sources/ACP/UI/ACPComposerShell.swift`

- [ ] **Step 1: Add a focus request parameter to `ACPInputField`**

In `Alas/Sources/ACP/UI/ACPComposer.swift`, add the stored property near `@Binding var isFocused`:

```swift
    let focusRequest: Int
```

Update the `ACPInputField` initializer call in `ACPComposerShell.swift` to pass the new value:

```swift
                focusRequest: focusRequest,
```

Expected: the project does not compile yet because `ACPComposer` does not define `focusRequest`.

- [ ] **Step 2: Add focus tracking in the AppKit coordinator**

In `ACPInputField.updateNSView`, after `context.coordinator.sendOnEnter = sendOnEnter`, add:

```swift
        if context.coordinator.focusRequest != focusRequest {
            context.coordinator.focusRequest = focusRequest
            if let tv = nsView.documentView as? ACPNSTextView,
               let window = tv.window {
                window.makeFirstResponder(tv)
            }
        }
```

In `ACPInputField.makeCoordinator()`, pass the token:

```swift
            focusRequest: focusRequest,
```

In `Coordinator`, add the stored property near `var sendOnEnter`:

```swift
        var focusRequest: Int
```

Update the coordinator initializer signature and assignment:

```swift
            focusRequest: Int,
```

```swift
            self.focusRequest = focusRequest
```

- [ ] **Step 3: Thread focus request through `ACPComposer`**

In `Alas/Sources/ACP/UI/ACPComposerShell.swift`, add a stored property near `sendOnEnter`:

```swift
    let focusRequest: Int
```

Update `ACPComposer.init` to accept a defaulted parameter before `onSubmit`:

```swift
        focusRequest: Int = 0,
```

Assign it in the initializer:

```swift
        self.focusRequest = focusRequest
```

Pass it into `ACPInputField`:

```swift
                focusRequest: focusRequest,
```

- [ ] **Step 4: Build to verify focus plumbing compiles**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
```

Expected: build succeeds.

- [ ] **Step 5: Commit**

```bash
git add Alas/Sources/ACP/UI/ACPComposer.swift Alas/Sources/ACP/UI/ACPComposerShell.swift
git commit -m "feat: let ACP composer refocus on request"
```

## Task 4: Add Composer Placement Mode

**Files:**
- Modify: `Alas/Sources/ACP/UI/ACPComposerShell.swift`

- [ ] **Step 1: Add placement type**

At the top of `Alas/Sources/ACP/UI/ACPComposerShell.swift`, after the imports, add:

```swift
enum ACPComposerPlacement: Equatable {
    case bottom
    case raisedEmpty
}
```

Add a stored property to `ACPComposer`:

```swift
    let placement: ACPComposerPlacement
```

Update `ACPComposer.init` to accept a defaulted placement:

```swift
        placement: ACPComposerPlacement = .bottom,
```

Assign it:

```swift
        self.placement = placement
```

- [ ] **Step 2: Split the composer layout body**

Replace the current `var body: some View` in `ACPComposer` with:

```swift
    var body: some View {
        Group {
            switch placement {
            case .bottom:
                bottomBody
            case .raisedEmpty:
                raisedEmptyBody
            }
        }
    }

    private var bottomBody: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            composerRow
                .padding(.bottom, 18)
                .padding(.top, 28)
        }
        .background(bottomShim)
    }

    private var raisedEmptyBody: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            composerRow
                .padding(.top, 320)
            Spacer(minLength: 110)
        }
    }

    private var composerRow: some View {
        HStack {
            Spacer(minLength: 0)
            pill.frame(maxWidth: 720)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
    }

    private var bottomShim: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0.0),
                .init(color: .clear, location: 0.55),
                .init(color: theme.color("bg-1").opacity(0.55), location: 1.0),
            ],
            startPoint: .top, endPoint: .bottom
        )
        .allowsHitTesting(false)
    }
```

The `raisedEmptyBody` keeps the composer above the bottom while remaining responsive to pane height. If this looks too low or high in manual verification, adjust only the `padding(.top, 320)` and `Spacer(minLength: 110)` constants.

- [ ] **Step 3: Build to verify placement compiles**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
```

Expected: build succeeds and existing `ACPComposer` call sites still compile because placement defaults to `.bottom`.

- [ ] **Step 4: Commit**

```bash
git add Alas/Sources/ACP/UI/ACPComposerShell.swift
git commit -m "feat: add raised ACP composer placement"
```

## Task 5: Add the Welcome and Starter Chip View

**Files:**
- Create: `Alas/Sources/ACP/UI/ACPNewChatEmptyStateView.swift`

- [ ] **Step 1: Create the new empty-state view**

Create `Alas/Sources/ACP/UI/ACPNewChatEmptyStateView.swift`:

```swift
import SwiftUI

struct ACPNewChatEmptyStateView: View {
    let agentDisplayName: String
    let onStarterPrompt: (ACPStarterPrompt) -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 14) {
            mark
            VStack(spacing: 5) {
                Text("What should we work on?")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(theme.color("fg"))
                Text("Start with a task, a file, or a rough idea.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(theme.color("fg-dim"))
            }
            starterChips
        }
        .frame(maxWidth: 640)
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .padding(.bottom, 210)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("New \(agentDisplayName) chat")
    }

    private var mark: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(
                    LinearGradient(
                        colors: [
                            theme.color("accent-soft"),
                            theme.color("bg-2").opacity(0.45),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(theme.color("accent").opacity(0.28), lineWidth: 0.75)
            Image(systemName: "sparkle")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(theme.color("accent"))
        }
        .frame(width: 40, height: 40)
    }

    private var starterChips: some View {
        HStack(spacing: 8) {
            ForEach(ACPStarterPrompt.allCases) { prompt in
                Button {
                    onStarterPrompt(prompt)
                } label: {
                    Text(prompt.label)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(theme.color("fg-muted"))
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .background(theme.color("bg-2").opacity(0.58))
                        .overlay(
                            RoundedRectangle(cornerRadius: 7)
                                .strokeBorder(theme.color("line"), lineWidth: 0.6)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .help(prompt.promptText)
            }
        }
    }
}
```

- [ ] **Step 2: Regenerate the Xcode project**

Run:

```bash
xcodegen
```

Expected: succeeds.

- [ ] **Step 3: Build to verify the new view compiles**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
```

Expected: build succeeds.

- [ ] **Step 4: Commit**

```bash
git add Alas/Sources/ACP/UI/ACPNewChatEmptyStateView.swift Alas.xcodeproj
git commit -m "feat: add ACP new chat welcome view"
```

## Task 6: Wire the Empty State into `ACPTabView`

**Files:**
- Modify: `Alas/Sources/ACP/UI/ACPTabView.swift`

- [ ] **Step 1: Add local animation and focus state**

Inside `ACPSessionView`, near the existing `@State private var showPlanSidebar`, add:

```swift
    @State private var composerFocusRequest: Int = 0
```

Add these computed properties near `isConnecting`:

```swift
    private var isNewEmptySession: Bool {
        ACPNewChatEmptyStatePolicy.isVisible(for: session)
    }

    private var composerPlacement: ACPComposerPlacement {
        isNewEmptySession ? .raisedEmpty : .bottom
    }

    private var emptyStateAnimation: Animation {
        .spring(response: 0.32, dampingFraction: 0.86)
    }
```

- [ ] **Step 2: Add starter prompt insertion**

Inside `ACPSessionView`, add this method near `handleEscape()`:

```swift
    private func insertStarterPrompt(_ starter: ACPStarterPrompt) {
        let next = starter.applying(to: session.composerDraft)
        manager.persistComposerDraft(next, for: session)
        composerFocusRequest += 1
    }
```

- [ ] **Step 3: Render the welcome overlay and pass composer mode**

In `transcriptAndComposer`, replace the `if isConnecting { ... } else { ACPMessageList(...) }` branch with this structure:

```swift
                    if isConnecting {
                        ACPConnectingPlaceholder(
                            agentDisplayName: state.agent(id: session.agentId)?.displayName ?? session.agentId
                        )
                    } else {
                        if isNewEmptySession {
                            ACPNewChatEmptyStateView(
                                agentDisplayName: state.agent(id: session.agentId)?.displayName ?? session.agentId,
                                onStarterPrompt: insertStarterPrompt
                            )
                            .transition(
                                .opacity.combined(with: .move(edge: .top))
                            )
                        } else {
                            ACPMessageList(
                                session: session,
                                transcript: session.transcript,
                                onOpenDiff: { relativePath in
                                    state.openDiffTab(forFileInWorktree: worktree, relativePath: relativePath)
                                },
                                policy: manager.runners[sessionId]?.policy,
                                scopeKey: scopeKey(for: session.transcript.pendingPermission),
                                onQueueEdit: { item in
                                    guard let restored = session.takeForEditing(id: item.id) else { return }
                                    manager.persistComposerDraft(
                                        session.composerDraft.appending(restored), for: session)
                                    manager.persistQueue(for: session)
                                    manager.runners[sessionId]?.flushQueueIfIdle()
                                },
                                onQueueRemove: { id in
                                    session.removeFromQueue(id: id)
                                    manager.persistQueue(for: session)
                                    manager.runners[sessionId]?.flushQueueIfIdle()
                                },
                                onQueueRetry: { id in
                                    guard let idx = session.queue.firstIndex(where: { $0.id == id }) else { return }
                                    session.queue[idx].lastError = nil
                                    manager.persistQueue(for: session)
                                    manager.runners[sessionId]?.flushQueueIfIdle()
                                },
                                onQueueReorder: { src, dst in
                                    session.moveInQueue(from: src, to: dst)
                                    manager.persistQueue(for: session)
                                    manager.runners[sessionId]?.flushQueueIfIdle()
                                },
                                onQueueClearAll: {
                                    session.clearPendingQueue()
                                    manager.persistQueue(for: session)
                                    manager.runners[sessionId]?.flushQueueIfIdle()
                                },
                                onLoadFullToolCallContent: { toolCallId in
                                    manager.reloadFullToolCallContent(
                                        sessionId: sessionId, toolCallId: toolCallId)
                                }
                            )
                            .transition(.opacity)
                        }
                    }
```

In the `ACPComposer` call, add:

```swift
                        placement: composerPlacement,
                        focusRequest: composerFocusRequest,
```

Add this modifier to the outer `ZStack(alignment: .bottom)`:

```swift
                    .animation(emptyStateAnimation, value: isNewEmptySession)
```

- [ ] **Step 4: Build to catch integration errors**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
```

Expected: build succeeds.

- [ ] **Step 5: Run focused tests**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test -only-testing:AlasTests/ACPNewChatEmptyStateTests
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Alas/Sources/ACP/UI/ACPTabView.swift
git commit -m "feat: show ACP new chat empty state"
```

## Task 7: Final Verification and Polish

**Files:**
- Modify only when verification reveals a concrete issue:
  - `Alas/Sources/ACP/UI/ACPComposerShell.swift`
  - `Alas/Sources/ACP/UI/ACPNewChatEmptyStateView.swift`
  - `Alas/Sources/ACP/UI/ACPTabView.swift`

- [ ] **Step 1: Run required project generation**

Run:

```bash
xcodegen
```

Expected: succeeds.

- [ ] **Step 2: Run the required build**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
```

Expected: succeeds.

- [ ] **Step 3: Run the full test suite**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test
```

Expected: succeeds.

- [ ] **Step 4: Manual verification**

Run the app from Xcode or the built product and verify:

```text
1. Create a new ACP chat tab.
2. Confirm the loading skeleton appears during attach.
3. Confirm the new empty state appears after the session is ready and still has no transcript messages.
4. Click "Review current changes" and confirm the full prompt appears in the composer and the text view is focused.
5. Type a note, click "Plan a feature", and confirm the new prompt appends after a blank line.
6. Submit the first prompt and confirm the welcome fades/slides out while the composer animates down.
7. Reopen a previous ACP session and confirm the old loading/restore path appears instead of the new empty state.
```

- [ ] **Step 5: Apply any measured layout polish**

If manual verification shows the raised composer is visibly too low or too high, adjust only these constants in `ACPComposerShell.swift`:

```swift
                .padding(.top, 320)
            Spacer(minLength: 110)
```

Run the build again after any adjustment:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
```

Expected: succeeds.

- [ ] **Step 6: Commit final polish if files changed**

```bash
git status --short
git add Alas/Sources/ACP/UI/ACPComposerShell.swift Alas/Sources/ACP/UI/ACPNewChatEmptyStateView.swift Alas/Sources/ACP/UI/ACPTabView.swift Alas.xcodeproj
git commit -m "polish: tune ACP new chat empty state"
```

If `git status --short` shows no changes after verification, skip this commit.
