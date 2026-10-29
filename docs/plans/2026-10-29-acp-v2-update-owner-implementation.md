# ACP 2 ordered update owner implementation plan

> **For agentic workers:** Use superpowers:executing-plans with the approved native inline method. TDD per task, one fresh whole-change review, one material fix pass. Keep changes uncommitted until shipping is requested.

**Goal:** Own ordered v2 journal restoration, live reduction and explicit post-commit consumption without activating production v2.

**Architecture:** A MainActor ACPV2SessionUpdateOwner in AlasSessions owns one canonical state and one stream iteration. It uses a narrow asynchronous journal interface implemented by the existing persistence actor. Tests wrap real SQLite operations with event gates, never replace durability with a fake.

**Tech stack:** Swift 6, Swift Testing, AsyncStream, existing SQLite/lease persistence.

**Spec:** [Approved design](2026-10-29-acp-v2-update-owner-design.md).

## Global constraints

- Branch nacho/acp-v2-update-owner, base 27887ab58c1335b2a9e6b9846f571f6c2c6395de. Preserve unrelated untracked adapter research.
- Production selection stays v1-only. No v1 runner edits, prompt dispatch, queue/UI projection, remote resume or new ACK transport.
- One task consumes one stream. Require immutable context, captured lease fence and synchronous current-attachment predicate. Stop invalidates synchronously; every awaited store result is rechecked before publication or consumption.
- Replay uses snapshot provenance. Broker backlog through the validated open snapshot journalTail also uses snapshot. Newer broker cursors and fresh stdio deliveries use live.
- Stored unknown valid events may be consumed; malformed/session-mismatched events stop after retaining bytes, without consumption or applying later updates.
- No automatic commit, push or PR. Focused package tests first; native app checks only if app integration seams change.

## Files and interfaces

Create `Packages/AlasCore/Sources/AlasSessions/ACP/Session/ACPV2SessionUpdateOwner.swift` containing the owner and its small journal interface. Create `Packages/AlasCore/Tests/AlasCoreTests/ACPV2SessionUpdateOwnerTests.swift` for this new type. The existing persistence actor conforms to the asynchronous interface through an extension; existing storage behavior stays unchanged.

`ACPV2UpdateJournalPersisting: Sendable` exposes async throwing registerV2UpdateJournal, appendV2Update and loadV2UpdateJournalPage with the existing parameter/result types. The page witness includes explicit maxRecords/maxBytes. Production actor witnesses retain real lease transactions; test wrappers only gate entry/return and forward to it.

`@MainActor final class ACPV2SessionUpdateOwner`:
- Nested immutable Attachment has `init(freshStdioConnectionID: UUID)` and throwing `init(brokerConnectionID: UUID, opened: ACPBrokerOpenResult)`. It derives source/connection and historical cursor after checking raw-v2, positive SQLite-range generation, unknown raw turn state, absent legacy caches, and SQLite-range journalTail. Journal registration still validates the current descriptor.
- Initializer binds sessionId, upstreamSessionId, attachment, fence, journal:any ACPV2UpdateJournalPersisting and required `isCurrent: @MainActor () -> Bool`.
- Public read-only state, stream, lastAppliedOrdinal, hasKnownMissingPrefix, status and latest application summary. Summaries carry ordinal/source/disposition/effects, not another full raw frame. A latest-only AsyncStream of revisioned observations reports changes; it is explicitly lossy, so consumers reread canonical state and never use it as a reliable queue-effect channel.
- `start(_ deliveries: AsyncStream<ACPV2SessionUpdateDelivery>) -> Bool` starts once; false on repeat. `stop()` synchronously invalidates/cancels and finishes observations. `waitUntilFinished() async` drains owned work.
- Typed failure categories distinguish ownership loss, source mismatch, ordinal gap, journal errors, other persistence errors, interpretation error and upstream-session mismatch. Unexpected EOF loses canonical observation; intentional stop does not fabricate disconnect/completion.

## Review focus

1. An owner stopped while COMMIT is returning must not apply or acknowledge the committed record. Task 2 gates both sides of append.
2. A duplicate broker event with a new connection/origin must be acknowledged by its current handle without applying its chunk again. Task 1 covers restore plus redelivery.
3. Previously unjournaled broker running/idle backlog must not become a live completion. Task 1 pins the open-tail boundary.
4. Malformed/wrong-session records cannot be skipped while later idle invents success. Task 2 verifies blocked prefix, retained bytes and zero later effects.
5. Replay pages or database errors must not produce a complete model or consume anything. Tasks 1/2 cover bounded replay, gaps and storage failures.

## Task 1: Ordered restoration, live ingestion and source boundaries

Interfaces produced: journal interface, owner/Attachment/state/status/application/observation APIs above.

- [x] Add failing tests in the new owner suite using real SQLite: sequential chunks and copied retries; restore plus broker redelivery; open-tail backlog vs newer live running/idle; bounded multipage replay and missing-prefix metadata. Assert exact canonical content, journal rows, ordinals, callback timing and no historical completion.
- [x] Run focused owner tests and observe missing contract RED.
- [x] Implement owner startup registration, bounded replay, identity validation, sequential append, trial reduction, ordinal deduplication and explicit original-handle consumption. One managed task, no arbitrary projection callbacks. Add actor conformance without changing SQLite operations.
- [x] Run owner plus canonical state, delivery, journal-related negotiation/restore suites. Inspect selected counts. Record GREEN and decisions in ledger. No commit.

## Task 2: Failure and attachment lifecycle fencing

Consumes Task 1 owner and journal interface. A test actor wraps real persistence and gates register/page/append before or after forwarding; no production test-only hooks.

- [x] Add failing regressions for stop during registration/page/append return, predicate invalidation after commit, stale lease before append and real trigger-induced write failure. Each asserts no late model publication/ACK. Persisted committed bytes survive.
- [x] Add parameterized malformed-known/invalid-envelope/wrong-session and source/connection/gen mismatch regressions; unknown valid event remains unhandled and durable. Add unexpected ordinal gap from real corrupted journal, repeated start, intentional stop vs EOF while foreground running.
- [x] Run focused tests and observe relevant RED before implementing missing guards/typed outcomes.
- [x] Implement synchronous invalidation, post-await guards, failure classification and blocked-prefix behavior. Do not catch errors as successful EOF. Do not consume queued or in-flight deliveries on stop.
- [x] Run affected package suites and read actual test counts. No commit.

## Task 3: Final verification, review and tracking

- [x] Run full SwiftFormat lint plus tracked/new-file whitespace checks. Run final affected package selection; no app build required if only new owner and package tests change.
- [x] Dispatch one fresh whole-change reviewer against fixed base including untracked owner/tests/docs and excluding unrelated research. Concrete review question: can replay/live ordering or a persistence-await ownership race duplicate application or authorize stale consumption? Fix material findings in one RED/GREEN pass; no rereview. Record deferred minors.
- [x] Update umbrella #2213 as locally implemented only, with precise evidence and excluded production activation. Complete plan/ledger. Leave work uncommitted for user review.

## Preflight and execution rulings

Task 1's exact owner/journal signatures feed Task 2's real-store gate wrapper; no shared-interface conflict. Task 3 validates the same fixed-base diff. The approved design leaves observer API to the builder: use bounded latest-state observations and readable state, not unbounded raw/effect history. Consumers cannot infer every effect from that observer.

Existing approved inline execution and no-commit policy override generic plan handoff/commit menus. The repository's focused-testing policy overrides generic full-suite defaults. No additional execution approval is needed after approval of the full design.

## Final evidence and handoff

The missing owner/journal API and broker UUID accessor each produced compiler RED before implementation. The owner suite additionally exercises already-present safety guards without deleting correct code to manufacture failures. The final selection passed 110 tests in 11 suites, including canonical lifecycle/message/activity, delivery, broker client/helper/response, restore and negotiation suites. Source code did not change after that run. Full SwiftFormat reported 0/2683 files requiring formatting, 1 skipped; tracked/new-file whitespace checks passed.

One fresh final review found no actionable Critical, Important or Minor findings. No fix pass or rereview was needed. Its exclusions match the approved scope: production activation, prompt/queue/UI integration, live adapters, and atomic cross-process COMMIT-to-ACK guarantees. Required caller authority plus journal lease fencing remains explicit.

Changes are confined to package code/tests and plans. No app target, CI, live adapter or SSH result is claimed. The v1 runner is unchanged and production supported versions remain v1-only. No commit, push or PR was made. The implementation is ready for local review on nacho/acp-v2-update-owner; unrelated adapter research is preserved.
