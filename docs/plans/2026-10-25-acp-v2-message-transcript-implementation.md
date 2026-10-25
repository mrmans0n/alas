# ACP v2 message transcript implementation plan

> **For agentic workers:** Use superpowers:executing-plans to implement this plan task by task.

**Goal:** Preserve v2 message updates and reduce them by exact entity identity, with deterministic local-prompt reconciliation effects.

**Architecture:** A raw-preserving v2 notification-params decoder produces typed message mutations. A UI-free reducer owns ordered upstream entities and local request bindings in one immutable connection/session context. Effects describe message changes and reconciliation without UI, persistence, transport, or lifecycle side effects.

**Tech stack:** Swift, Swift Testing, existing AlasACP package target.

**Spec:** [Approved design](2026-10-25-acp-v2-message-transcript-design.md).

## Global constraints

- No live v2 selection, v1 changes, UI projection, persistence migration, replay/resume, or adapter changes.
- Preserve all raw notification params and raw content blocks; JSON-value equality is the wire round-trip contract.
- No content-based prompt matching, chunk deduplication, invented separators, or foreground-completion effects.
- Keep work local until a shipping request and preserve the pre-existing research note.
- Reuse the existing isolated SwiftPM scratch/cache paths. Run affected package suites, not the entire local test plan.

## Review focus

- Consecutive identical chunks append twice; a replacement after chunks discards their content.
- Message, chunk, and notification metadata have distinct scopes; nested metadata objects replace rather than merge.
- Context mismatches cannot bind reused request IDs or mutate the same ID in another session.
- Response-first binding cannot seed content with the optimistic text; echo-first binding must identify the existing entity.
- Conflicting request, row, or message bindings must leave prior valid associations intact.

## Task 1: Lossless v2 message envelopes

Files: create `Packages/AlasCore/Sources/AlasACP/ACP/Protocol/ACPV2SessionUpdateEnvelope.swift`; create `Packages/AlasCore/Tests/AlasCoreTests/ACPV2MessageTranscriptTests.swift`.

Interfaces: `ACPV2SessionUpdateEnvelope: Equatable, Sendable` decodes notification params through `decode(from: Data)` and encodes through `encodedData()`. It exposes `sessionID`, `rawValue`, and optional typed `message`. Nested message values expose `kind`, `messageID`, `content` mutation, and `metadata` patch. Unknown string variants have no typed mutation; malformed known shapes throw. The full params object is encoded unchanged, using the raw JSON codec rather than generic Codable so opaque numeric tokens remain intact.

- [x] Add `messageEnvelopesKeepRawFields` for all six variants, `unhandledUpdatesStayLossless`, and parameterized `malformedKnownShapesAreRejected`. Assert JSON-value round trips and omission/null/concrete content distinctions.
- [x] Run the new suite and observe the missing decoder contract before implementation.
- [x] Implement strict required fields/container shapes and structured raw blocks. Keep chunk/notification metadata out of entity patches.
- [x] Run the new suite; inspect the actual count and result.

## Task 2: Ordered canonical messages

Files: create `Packages/AlasCore/Sources/AlasACP/ACP/Session/ACPV2MessageTranscript.swift`; extend the same test suite.

Interfaces: `ACPV2MessageTranscript` has an immutable `Context(sessionID: String, connectionID: UUID)`, ordered `messages`, and a lookup by `Key(kind:messageID:)`. `apply(_:context:) -> Reduction` returns the original event plus an explicit disposition and changed-entity effects. Entities retain structured `content`, effective `metadata`, and optional local row binding. Foreign contexts/session IDs leave state intact.

- [x] Add ordered content traces, top-level metadata patch traces, type-plus-ID identity, and foreign-context rejection. Observe the missing reducer contract.
- [x] Implement first-observed entity order, omission/null/replacement/append semantics, and metadata patching. Return changed effects only for observable changes; every chunk is applied.
- [x] Run the new suite and existing lifecycle/negotiation suites; inspect results.

## Task 3: Exact submission correlation and final review

Files: extend the reducer and its existing suite.

Interfaces: `register(requestID:localRowID:context:)` registers opaque local UUID handles; `accept(requestID:response:context:)` consumes `ACPV2PromptAccepted` for that exact registered request. Return explicit registered/bound/reconciled/unchanged/unmatched/conflict/stale outcomes. Bindings neither create upstream entities nor supply their content. Effects identify the user entity and local row; the owner later preserves metadata and applies UI/database changes.

- [x] Add both response/echo orders, identical messages with reversed responses, repeated/conflicting acceptance, reused local handles, and stale/missing registration cases. Observe failures before adding the interfaces.
- [x] Implement atomic conflict checks before mutation, exact reverse bindings, and reconciliation effects for the already-observed or first-observed entity. Do not duplicate lifecycle status or add rejection/retry side effects.
- [x] Run the final focused package selection, inspect counts, check whitespace and the full diff, and obtain one fresh-context review. Fix actionable findings with regression evidence.
- [x] Update plan and umbrella with locally complete versus deferred work. Defer commits/PR publication until a shipping request.

## Result

Implemented on `nacho/acp-v2-message-transcript` at baseline `3b1dfc8cb96f3405edda8c53e156408714673526`. The change adds two package source files and one coherent test suite. No existing v1, UI, persistence, transport, or eligibility source changed. Commit and PR publication were subsequently authorized.

Validation on 2026-10-25:

- The new wire contract, reducer, and correlation APIs each failed compilation when their tests were introduced before the implementation existed.
- Final focused run: 33 tests in 3 suites passed, covering `ACPV2MessageTranscriptTests`, `ACPSessionLifecycleTests`, and `ACPProtocolNegotiationTests`. Log: `/private/tmp/alas-acp2-message-final.log`.
- Independent review found no Critical, Important, or Minor issues. The reviewer checked both delivery orders, repeated acceptance, stale contexts, atomic conflicts, raw number preservation, and content/metadata semantics.
- Whitespace checks passed for all new files. No app build, CI run, or live adapter probe ran for this package-only slice.

The wire decoder uses explicit raw JSON `decode(from:)` and `encodedData()` entry points to retain arbitrary numeric tokens. Generic Codable is deliberately absent. UI projection, durable storage, replay/resume, non-message handlers, and live v2 integration remain later work; all production connections continue to use v1.

Umbrella [#2213](https://github.com/mrmans0n/alas/issues/2213) now records the locally validated foundation steps separately from full transcript/restoration integration. The issue update was fetched again and verified.
