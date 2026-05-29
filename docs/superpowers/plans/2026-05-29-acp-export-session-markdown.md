# ACP Session → Markdown Export & Per-Message Copy Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user extract ACP conversation text as Markdown — whole-session copy/save from the tab context menu, plus a hover-revealed per-message copy button.

**Architecture:** One pure serializer (`ACPTranscriptMarkdown`) is the single source of truth for formatting. Two thin call sites consume it: `AppState` methods (clipboard + `NSSavePanel`) wired through the tab context menu, and a hover copy button on user/agent rows in `ACPMessageList`. Output is conversation-only (`.user` + `.agent`), read straight from the in-memory `transcript.messages` (no SQLite round-trip, since only tool-call content is ever truncated off-window).

**Tech Stack:** Swift 5.9+, SwiftUI (macOS), AppKit (`NSPasteboard`, `NSSavePanel`), Swift Testing framework (`import Testing`, `@Suite`, `@Test`, `#expect`).

---

## Spec

`docs/superpowers/specs/2026-05-29-acp-export-session-markdown-design.md`

## Conventions (from AGENTS.md — IMPORTANT)

- Tests use **Swift Testing** (`import Testing`), **not** XCTest.
- **No agent attributions anywhere** — no `Co-Authored-By`, no "Generated with…", no 🤖, in commits/PRs/code/comments. Commit messages must read as if written by the human author.
- Keep code, comments, and UI strings in English.

## Commands

- **Build:**
  `xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build`
- **Run just this feature's unit tests:**
  `xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ACPTranscriptMarkdownTests test`
- **Full test suite:**
  `xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test`

> Note: `xcodebuild` is slow to spin up. The single-suite `-only-testing:` form is the fast inner loop for Task 1. A test "fails to compile because the symbol doesn't exist yet" counts as a valid red (FAIL) state in TDD here.

## File Structure

- **Create** `Alas/Sources/ACP/Session/ACPTranscriptMarkdown.swift` — pure serializer. Responsibility: turn a transcript (or one message) into Markdown text, and a title into a safe filename. No UI, no I/O.
- **Create** `AlasTests/ACP/Session/ACPTranscriptMarkdownTests.swift` — unit tests for the serializer.
- **Modify** `Alas/Sources/App/AppState.swift` — add `copyACPSessionMarkdown`, `exportACPSessionMarkdown`, and a private `acpSession(worktreeId:tabId:)` resolver.
- **Modify** `Alas/Sources/Center/TabBarView.swift` — two new callbacks + two menu buttons in the `.acpSession` case.
- **Modify** `Alas/Sources/Center/CenterPaneView.swift` — wire the two callbacks to `AppState`.
- **Modify** `Alas/Sources/ACP/UI/ACPMessageList.swift` — hover-revealed copy button on `UserMessageRow` and `AgentMessageRow`; add a small `ACPHoverCopyButton` view.
- **Modify** test constructors that build `TabBarView`: `AlasTests/TouchTargetSmokeTests.swift`, `AlasTests/TabActivityIconTintTests.swift` — add the two new callback arguments.

---

## Task 1: `ACPTranscriptMarkdown` serializer (pure core, TDD)

**Files:**
- Create: `Alas/Sources/ACP/Session/ACPTranscriptMarkdown.swift`
- Test: `AlasTests/ACP/Session/ACPTranscriptMarkdownTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `AlasTests/ACP/Session/ACPTranscriptMarkdownTests.swift`:

```swift
import Foundation
import Testing
@testable import Alas

@MainActor
@Suite("ACPTranscriptMarkdown")
struct ACPTranscriptMarkdownTests {
    @Test("document renders user + agent only, in order, with role headings")
    func documentRendersConversation() {
        let messages: [ACPMessage] = [
            .user(id: UUID(), text: "hi", attachments: []),
            .thought(id: UUID(), StreamingText("secret reasoning")),
            .agent(id: UUID(), StreamingText("hello")),
            .toolCall(.init(toolCallId: "t1", title: "Read", status: "completed")),
            .plan(id: UUID(), []),
            .systemNotice(id: UUID(), text: "noticed"),
        ]
        let md = ACPTranscriptMarkdown.document(
            title: "Chat", agentName: "Claude Code", messages: messages)
        #expect(md == "# Chat\n\n## You\n\nhi\n\n## Claude Code\n\nhello\n")
    }

    @Test("document falls back to default title and agent heading")
    func documentFallbacks() {
        let messages: [ACPMessage] = [.agent(id: UUID(), StreamingText("yo"))]
        #expect(
            ACPTranscriptMarkdown.document(title: "New session", agentName: nil, messages: messages)
            == "# ACP session\n\n## Agent\n\nyo\n")
        #expect(
            ACPTranscriptMarkdown.document(title: "   ", agentName: "  ", messages: messages)
            == "# ACP session\n\n## Agent\n\nyo\n")
    }

    @Test("empty conversation renders just the title line")
    func documentEmpty() {
        #expect(
            ACPTranscriptMarkdown.document(title: "", agentName: nil, messages: [])
            == "# ACP session\n")
    }

    @Test("message bodies pass through verbatim (markdown not mangled)")
    func documentVerbatim() {
        let raw = "## Heading\n\n- a\n- b\n\n```swift\nlet x = 1\n```"
        let messages: [ACPMessage] = [.agent(id: UUID(), StreamingText(raw))]
        let md = ACPTranscriptMarkdown.document(title: "T", agentName: "A", messages: messages)
        #expect(md == "# T\n\n## A\n\n\(raw)\n")
    }

    @Test("messageBody returns raw text for user/agent, nil otherwise")
    func messageBody() {
        #expect(ACPTranscriptMarkdown.messageBody(
            .user(id: UUID(), text: "u", attachments: [])) == "u")
        #expect(ACPTranscriptMarkdown.messageBody(
            .agent(id: UUID(), StreamingText("a"))) == "a")
        #expect(ACPTranscriptMarkdown.messageBody(
            .thought(id: UUID(), StreamingText("t"))) == nil)
        #expect(ACPTranscriptMarkdown.messageBody(
            .toolCall(.init(toolCallId: "t1", title: "Read", status: "done"))) == nil)
        #expect(ACPTranscriptMarkdown.messageBody(
            .systemNotice(id: UUID(), text: "s")) == nil)
    }

    @Test("sanitizedFilename strips illegal chars and appends .md")
    func sanitizedFilename() {
        #expect(ACPTranscriptMarkdown.sanitizedFilename(title: "a/b\nc") == "a-b-c.md")
        #expect(ACPTranscriptMarkdown.sanitizedFilename(title: "Hello World") == "Hello-World.md")
        #expect(ACPTranscriptMarkdown.sanitizedFilename(title: "New session") == "acp-session.md")
        #expect(ACPTranscriptMarkdown.sanitizedFilename(title: "   ") == "acp-session.md")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ACPTranscriptMarkdownTests test`
Expected: FAIL — compile error, `cannot find 'ACPTranscriptMarkdown' in scope`.

- [ ] **Step 3: Write the serializer**

Create `Alas/Sources/ACP/Session/ACPTranscriptMarkdown.swift`:

```swift
import Foundation

/// Pure Markdown serialization of an ACP conversation. No UI, no I/O.
///
/// Conversation-only: renders `.user` and `.agent` messages and omits
/// every other kind (thought, tool call, file edit, plan, system notice).
/// This is the single source of truth for formatting so whole-session
/// export and per-message copy render identically.
///
/// Reading an agent message's text touches `StreamingText.value`, which is
/// `@MainActor`-isolated, so the rendering entry points are `@MainActor`.
enum ACPTranscriptMarkdown {
    /// Whole conversation → Markdown document.
    /// - Parameters:
    ///   - title: session title; empty or "New session" falls back to "ACP session".
    ///   - agentName: display name for the agent heading; nil/blank falls back to "Agent".
    ///   - messages: full transcript in order. Non-conversation kinds are filtered out.
    @MainActor
    static func document(title: String, agentName: String?, messages: [ACPMessage]) -> String {
        let agentHeading = trimmedNonEmpty(agentName) ?? "Agent"
        var sections: [String] = ["# \(headerTitle(title))"]
        for message in messages {
            switch message {
            case .user(_, let text, _):
                sections.append("## You\n\n\(text)")
            case .agent(_, let buffer):
                sections.append("## \(agentHeading)\n\n\(buffer.value)")
            default:
                continue
            }
        }
        return sections.joined(separator: "\n\n") + "\n"
    }

    /// One message's raw Markdown source, or nil for non-conversation kinds.
    @MainActor
    static func messageBody(_ message: ACPMessage) -> String? {
        switch message {
        case .user(_, let text, _): return text
        case .agent(_, let buffer): return buffer.value
        default: return nil
        }
    }

    /// Session title → filesystem-safe `.md` filename.
    static func sanitizedFilename(title: String) -> String {
        let base = trimmedNonEmpty(title).flatMap { $0 == "New session" ? nil : $0 } ?? "acp-session"
        let illegal = CharacterSet(charactersIn: "/\\:?%*|\"<>")
            .union(.newlines)
            .union(.controlCharacters)
        let cleaned = base.components(separatedBy: illegal).joined(separator: "-")
        let collapsed = cleaned.replacingOccurrences(of: " ", with: "-")
        let safe = collapsed.isEmpty ? "acp-session" : collapsed
        return "\(safe).md"
    }

    // MARK: - Helpers

    private static func headerTitle(_ title: String) -> String {
        trimmedNonEmpty(title).flatMap { $0 == "New session" ? nil : $0 } ?? "ACP session"
    }

    private static func trimmedNonEmpty(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ACPTranscriptMarkdownTests test`
Expected: PASS — all 6 tests green.

- [ ] **Step 5: Commit**

```bash
git add Alas/Sources/ACP/Session/ACPTranscriptMarkdown.swift AlasTests/ACP/Session/ACPTranscriptMarkdownTests.swift
git commit -m "feat(acp): add ACPTranscriptMarkdown conversation serializer"
```

---

## Task 2: `AppState` copy + export methods

No new unit test (these methods are thin glue over the Task 1 core plus AppKit clipboard/save-panel calls, which need a live UI session and modal panel — not unit-testable). Verification is a clean build. The serializer they call is already covered by Task 1.

**Files:**
- Modify: `Alas/Sources/App/AppState.swift` (add three methods near `saveActiveTabAs`, around line 1487)

- [ ] **Step 1: Add the methods**

Add to `AppState` (place after `renameACPSessionTab`, near line 1553):

```swift
    /// Copy the active ACP session's conversation (user + agent, Markdown)
    /// to the pasteboard. Silent on success, matching `onCopyPath`.
    func copyACPSessionMarkdown(worktreeId: String, tabId: TabID) {
        guard let session = acpSession(worktreeId: worktreeId, tabId: tabId) else { return }
        let markdown = ACPTranscriptMarkdown.document(
            title: session.title,
            agentName: agent(id: session.agentId)?.displayName,
            messages: session.transcript.messages
        )
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(markdown, forType: .string)
    }

    /// Save the active ACP session's conversation to a `.md` file via a
    /// save panel. Cancel is a no-op; write failures surface through the
    /// shared file-action error handler.
    func exportACPSessionMarkdown(worktreeId: String, tabId: TabID) {
        guard let session = acpSession(worktreeId: worktreeId, tabId: tabId) else { return }
        let markdown = ACPTranscriptMarkdown.document(
            title: session.title,
            agentName: agent(id: session.agentId)?.displayName,
            messages: session.transcript.messages
        )
        let panel = NSSavePanel()
        panel.title = "Save Session as Markdown"
        panel.message = "Choose where to save this conversation."
        panel.nameFieldStringValue = ACPTranscriptMarkdown.sanitizedFilename(title: session.title)
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try markdown.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            showFileActionError(title: "Export Failed", message: error.localizedDescription)
        }
    }

    /// Resolve the in-memory `ACPSession` backing an ACP session tab.
    /// Returns nil for non-ACP tabs or when the session has been evicted.
    private func acpSession(worktreeId: String, tabId: TabID) -> ACPSession? {
        guard let tab = tabs.tabs(forWorktree: worktreeId).first(where: { $0.id == tabId }),
              case .acpSession(let tabState) = tab,
              let worktree = worktree(withId: worktreeId),
              let mgr = acpManager(for: worktree) else { return nil }
        return mgr.sessions[tabState.sessionId]
    }
```

- [ ] **Step 2: Build to verify it compiles**

Run: `xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build`
Expected: Build succeeds. (`NSSavePanel`/`NSPasteboard` are available via the existing `import AppKit` at the top of `AppState.swift`; `agent(id:)`, `showFileActionError`, `acpManager(for:)`, and `tabs.tabs(forWorktree:)` already exist in this file.)

- [ ] **Step 3: Commit**

```bash
git add Alas/Sources/App/AppState.swift
git commit -m "feat(acp): AppState copy/export session as Markdown"
```

---

## Task 3: Tab context menu entries

**Files:**
- Modify: `Alas/Sources/Center/TabBarView.swift` (callbacks near line 17; menu buttons near line 70)
- Modify: `Alas/Sources/Center/CenterPaneView.swift` (wiring near line 56)
- Modify: `AlasTests/TouchTargetSmokeTests.swift`, `AlasTests/TabActivityIconTintTests.swift` (constructor call sites)

- [ ] **Step 1: Add the two callbacks to `TabBarView`**

In `Alas/Sources/Center/TabBarView.swift`, add after the existing `let onRenameACPSession: (TabID) -> Void` (line 17):

```swift
    let onCopyACPSession: (TabID) -> Void
    let onExportACPSession: (TabID) -> Void
```

- [ ] **Step 2: Add the menu buttons**

In the `.contextMenu` block, replace the existing `.acpSession` arm (lines 70–73):

```swift
                    if case .acpSession = tab {
                        Button("Rename…") { onRenameACPSession(tab.id) }
                        Divider()
                    }
```

with:

```swift
                    if case .acpSession = tab {
                        Button("Rename…") { onRenameACPSession(tab.id) }
                        Button("Copy Session as Markdown") { onCopyACPSession(tab.id) }
                        Button("Save Session as Markdown…") { onExportACPSession(tab.id) }
                        Divider()
                    }
```

- [ ] **Step 3: Wire the callbacks in `CenterPaneView`**

In `Alas/Sources/Center/CenterPaneView.swift`, after the `onRenameACPSession` argument (lines 56–58):

```swift
                onRenameACPSession: { id in
                    state.renameACPSessionTab(worktreeId: worktree.id, tabId: id)
                },
```

add:

```swift
                onCopyACPSession: { id in
                    state.copyACPSessionMarkdown(worktreeId: worktree.id, tabId: id)
                },
                onExportACPSession: { id in
                    state.exportACPSessionMarkdown(worktreeId: worktree.id, tabId: id)
                },
```

- [ ] **Step 4: Update test constructors of `TabBarView`**

In **both** `AlasTests/TouchTargetSmokeTests.swift` and `AlasTests/TabActivityIconTintTests.swift`, every `TabBarView(...)` literal currently passes `onRenameACPSession: { _ in },`. Immediately after each such line, add:

```swift
            onCopyACPSession: { _ in },
            onExportACPSession: { _ in },
```

(There are 4 call sites in `TouchTargetSmokeTests.swift` and 1 in `TabActivityIconTintTests.swift` — match the indentation of the surrounding arguments at each site.)

- [ ] **Step 5: Build to verify it compiles**

Run: `xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build`
Expected: Build succeeds. If it fails with "missing argument for parameter 'onCopyACPSession'", a `TabBarView(...)` construction site was missed — search the repo for `onRenameACPSession:` and add the two new args next to each.

- [ ] **Step 6: Run the touch-target smoke tests**

Run: `xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/TouchTargetSmokeTests -only-testing:AlasTests/TabActivityIconTintTests test`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Alas/Sources/Center/TabBarView.swift Alas/Sources/Center/CenterPaneView.swift AlasTests/TouchTargetSmokeTests.swift AlasTests/TabActivityIconTintTests.swift
git commit -m "feat(acp): copy/save session as Markdown in tab context menu"
```

---

## Task 4: Per-message hover copy button

SwiftUI hover/overlay affordances aren't meaningfully unit-testable; verification is a clean build plus the existing ACP UI smoke coverage. The text these buttons copy is the same raw body the Task-1 serializer returns for `.user`/`.agent`, so behavior is already covered by `ACPTranscriptMarkdownTests`.

**Files:**
- Modify: `Alas/Sources/ACP/UI/ACPMessageList.swift` (`UserMessageRow` ~line 416, `AgentMessageRow` ~line 465; add `ACPHoverCopyButton`)

- [ ] **Step 1: Add the reusable hover copy button**

In `Alas/Sources/ACP/UI/ACPMessageList.swift`, add near the other private row helpers (e.g. just above `private struct UserMessageRow`):

```swift
/// Hover-revealed affordance that copies a message's raw Markdown to the
/// pasteboard as plain text. The caller passes exactly the text
/// `ACPTranscriptMarkdown.messageBody` would return for this row.
private struct ACPHoverCopyButton: View {
    let markdown: String
    @Environment(\.theme) private var theme

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(markdown, forType: .string)
        } label: {
            Image(systemName: "doc.on.doc")
                .font(.system(size: 10.5))
                .foregroundStyle(theme.color("fg-muted"))
                .padding(4)
                .background(theme.color("bg-3").opacity(0.85))
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(theme.color("line"), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .help("Copy message as Markdown")
    }
}
```

- [ ] **Step 2: Add hover state + overlay to `UserMessageRow`**

`UserMessageRow` is right-aligned, so the button sits at the bubble's top-leading (outer) corner. Add `@State private var hovering = false` to the struct, then attach the overlay + hover to the inner `VStack(alignment: .trailing, ...)` (the one wrapping the bubble, ending `.frame(maxWidth: 540, alignment: .trailing)` at line ~457):

```swift
            .frame(maxWidth: 540, alignment: .trailing)
            .overlay(alignment: .topLeading) {
                if hovering {
                    ACPHoverCopyButton(markdown: text).offset(x: -6, y: -6)
                }
            }
            .onHover { hovering = $0 }
```

- [ ] **Step 3: Add hover state + overlay to `AgentMessageRow`**

`AgentMessageRow` is full-width left-aligned, so the button sits at the top-trailing corner. Add `@State private var hovering = false` to the struct and attach to its `ACPMarkdownText(...)` (line ~470):

```swift
        ACPMarkdownText(raw: buffer.value, cache: transcript.markdownCache(forMessage: messageId))
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .topTrailing) {
                if hovering {
                    ACPHoverCopyButton(markdown: buffer.value).offset(x: -2, y: -6)
                }
            }
            .onHover { hovering = $0 }
```

(`AgentMessageRow` already declares `@ObservedObject var buffer: StreamingText`, so `buffer.value` is in scope. Both rows already use `@Environment(\.theme)`; `NSPasteboard` is available via the file's existing `import AppKit`.)

- [ ] **Step 4: Build to verify it compiles**

Run: `xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build`
Expected: Build succeeds.

- [ ] **Step 5: Manual smoke check (visual)**

Launch the app, open an ACP session with at least one user prompt and one agent reply. Hover a user bubble and an agent reply — a copy button appears at the corner; clicking it puts that message's raw Markdown on the clipboard. Hovering a thought/tool-call/file-edit row shows no button.

- [ ] **Step 6: Commit**

```bash
git add Alas/Sources/ACP/UI/ACPMessageList.swift
git commit -m "feat(acp): hover-to-copy button on conversation messages"
```

---

## Task 5: Full verification

- [ ] **Step 1: Run the full test suite**

Run: `xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test`
Expected: PASS (no regressions; new `ACPTranscriptMarkdownTests` green).

- [ ] **Step 2: Final build**

Run: `xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build`
Expected: Build succeeds with no warnings introduced by these changes.

---

## Self-Review notes (author)

- **Spec coverage:** whole-session copy (Task 2/3) ✓, whole-session save-to-file (Task 2/3) ✓, per-message hover copy on user+agent (Task 4) ✓, conversation-only filtering (Task 1) ✓, verbatim raw Markdown (Task 1) ✓, role headings + title/agent fallbacks (Task 1) ✓, filename sanitization (Task 1) ✓, silent clipboard / save-error via `showFileActionError` (Task 2) ✓, read from in-memory transcript (Task 2) ✓, no toast (Tasks 2/4, silent) ✓.
- **Deferred per spec (not built):** tool/thought/system inclusion, true text selection, include-tool toggle, "Copied ✓" confirmation.
- **Type consistency:** `ACPTranscriptMarkdown.document(title:agentName:messages:)`, `.messageBody(_:)`, `.sanitizedFilename(title:)` used identically across Tasks 1–4. `acpSession(worktreeId:tabId:)` resolver returns `ACPSession?`. `onCopyACPSession` / `onExportACPSession` names consistent between `TabBarView`, `CenterPaneView`, and test constructors.
