# Editor Display Projection Feasibility Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox syntax for tracking.

**Goal:** Prove whether separate display storage can satisfy Task 14 geometry and editing requirements.

**Architecture:** Authoritative source storage feeds a separate attributed display storage. Virtual hint attachments have distinct display positions; explicit maps connect native presentation to source transactions.

**Tech Stack:** Swift Testing, AppKit, TextKit 1, isolated Swift package.

**Spec:** `docs/plans/2026-09-14-editor-display-projection-design.md`

## Global Constraints

- No production editor changes during this feasibility task.
- Source text, LSP, undo, find matches, and serialization use source UTF-16 positions.
- Virtual attachments occur only in display storage.
- Test evidence distinguishes automated AppKit calls from real keyboard/IME and accessibility verification.
- No agent attribution in commits or documents.

### Task 1: Prove display projection geometry and input

**Files:** Create an isolated package under `.superpowers/sdd/2026-09-13-code-editor-lsp-implementation/task14-display-probe/`; write evidence to `task-14-display-report.md` in the same SDD directory.

**Interfaces:** The prototype exposes source-to-display boundary mapping with before/after affinity, display-range-to-source mapping, and hit results distinguishing source from hint identity. Native NSTextView APIs remain display-based. Source replacement and undo are owned by the prototype source model.

- [ ] Read the design and original `task-14-report.md`; reuse its fixture text and measured assertions.
- [ ] Add an executable native geometry fixture with two display attachments of widths 12 and 40 at source offset 1. Assert their distinct rectangles, source `b` rectangle excluding attachments, and inverse mapping at either side of `b`.
- [ ] Extend fixtures to `a\tb` with tab stop 84, 60-point wrapping, `a🙂bc`, and `אבגד`; compare source boundaries and layout direction, and record actual native behavior.
- [ ] Implement only enough immutable run mapping and display assembly to make those fixtures meaningful. Reject invalid UTF-16 positions and retain hint identities for hits.
- [ ] Exercise NSTextView insertion, deletion spanning hints, copy, caret movement, selection preservation, and source-owned undo while refreshing the projection. Assert exact source text and that projection rebuild adds no undo action.
- [ ] Exercise `setMarkedText`, replacement of marked text, `unmarkText`, and deferred hint refresh. State clearly that these calls do not establish real input-method candidate-window behavior.
- [ ] Run the isolated Swift Testing package with caches and scratch output in `/private/tmp`; retain the command, exit status, counts, and failures in the evidence report.
- [ ] Report PASS, FAIL, or PARTIAL per geometry/input requirement; list concrete production integration consumers and unresolved risks. Do not promote prototype code into the app or claim Task 14 complete.

The next deliverable is a production integration plan based on the measured result, followed by independent review and the existing Task 14/15 gates.
