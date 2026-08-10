# Drag Paths and Commit SHAs Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Insert dragged worktree paths and commit SHAs into Alas agent composers and terminal panes.

**Architecture:** Extend the existing AppKit drag pipeline with a private typed pasteboard payload while preserving public file and text representations. Route whole-agent drops through the live composer and terminal drops through the hovered Ghostty surface.

**Tech Stack:** Swift 5.9+, SwiftUI, AppKit drag and pasteboard APIs, GhosttyKit, Swift Testing.

## Global Constraints

- Preserve current external copy-only file dragging.
- Agents receive repo-relative paths; terminals receive shell-escaped absolute paths.
- Insert text without surrounding whitespace, newline, submission, execution, or attachments.
- Remote and deleted files support internal text insertion only.
- Scope file sources to Files, Working Tree, and conflicts; scope SHA sources to existing click-to-copy labels.

---

### Task 1: Typed drag payload and source policy

- [ ] Add failing Swift Testing coverage for typed payload encoding, path/SHA text representations, operation masks, and remote/deleted internal-only items.
- [ ] Run focused tests and confirm failures are caused by missing typed-payload behavior.
- [ ] Implement the private payload, prepared drag item, public pasteboard fallbacks, and context-sensitive copy masks in the existing DragOut subsystem.
- [ ] Run the focused DragOut tests and commit the independently green slice.

### Task 2: Path and SHA drag sources

- [ ] Add failing coverage for path payload factories and full-SHA source payloads.
- [ ] Attach path payloads to Files-tab files/directories and Working Tree/conflict rows, including remote and deleted items.
- [ ] Attach full-SHA payloads to commit-row, commit-header, and parent-SHA labels without changing click or row behavior.
- [ ] Run focused source/model tests and commit the independently green slice.

### Task 3: Agent drop routing

- [ ] Add failing ACP tests for insertion at the retained selection, draft callbacks, focus, mirrored rejection, and no submission or attachment.
- [ ] Add a whole-chat typed drop destination and a router to the mounted AppKit composer.
- [ ] Preserve existing image drops and reject malformed or unrelated pasteboard data.
- [ ] Run focused ACP and drag tests and commit the independently green slice.

### Task 4: Terminal drop routing

- [ ] Add failing tests for POSIX shell escaping and typed terminal drop decoding through fake Ghostty IO.
- [ ] Register each Ghostty surface for the private payload, focus the hovered pane, and send exactly one formatted value through the existing IO seam.
- [ ] Reject malformed and unrelated pasteboard data without sending input.
- [ ] Run focused terminal and drag tests and commit the independently green slice.

### Task 5: Integration verification

- [ ] Run `xcodegen` and confirm generated project membership is current.
- [ ] Run all focused DragOut, ACP, commit-header, and SurfaceView tests.
- [ ] Run the required quiet macOS build and full test suite.
- [ ] Inspect the final diff for scope, formatting, generated-file changes, and accidental attribution before branch handoff.
