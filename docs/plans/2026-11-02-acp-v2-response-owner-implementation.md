# ACP v2 response owner implementation plan

> Execute inline with superpowers:executing-plans. The approved design authorizes this plan and implementation without another handoff menu. Leave changes uncommitted until shipping is requested.

**Goal:** Bind retained requests to current attachments, commit response attempts before one exact handoff, and retain write facts conservatively.

**Architecture:** Transport-owned reconciliation exposes original stdio capture eligibility and fresh broker pending views. An AlasSessions owner composes these with the existing lease-fenced persistence actor, gates each origin, and separates caller settlement from late fact retention.

**Tech stack:** Swift, Swift Testing, existing SQLite actor, ACP raw-v2 transports.

**Spec:** `docs/plans/2026-11-02-acp-v2-response-owner-design.md`

## Global constraints

Production remains v1-only. No schema changes, execution decisions, UI, inbound consumption or new ACK authority. Exact UTF-8 source identity and original bytes. No unresolved-attempt retry. Only newly inserted attempts may initiate handoff. Preserve unrelated Ghostty/research. One fresh final review, one combined material fix pass, no rereview. No commits before shipping request.

## Review focus

- Cancelled joined waiters must not cancel the initiating caller's operation. Task 3.
- Broker pending snapshots can change while persistence awaits; helper exact origin claim stays authoritative. Tasks 1/3.
- A copied historical attempt receipt cannot initiate a write after local owner replacement. Task 2.
- Late facts after invalidation can never revive success or bypass the lease fence. Task 3.
- Local owner fencing does not make SQLite and pipe writes an atomic distributed transaction. Explicitly document this limitation, Task 3.

## Task 1: Transport-owned current request reconciliation

Files: extend `ACPBrokerRawClientTests.swift`; extend stdio tests where captured origin behavior is already pinned. Modify `ACPStdioClient.swift`, `ACPV2StdioReply.swift`, `ACPRawBrokerTransport.swift`, `ACPBrokerClient.swift`; add `ACPBrokerPendingView.swift`.

Interfaces: `ACPStdioClient.canRespondToV2Request(_ delivery: ACPV2InboundDelivery) -> Bool`; `ACPBrokerClient.currentRawPendingRequests() async throws -> ACPBrokerPendingView`. View immutable, constructor module-internal, fields connectionID/brokerID/generation/journalTail/requests. Snapshot freshness via an explicit attach call, no accumulated historical map, no consumption side effects.

- [x] Add failing current-view regression for fresh pending, removal, reused cursor, detached attachment and duplicate/conflicting pending metadata; assert no ACK/response side effects. Run focused package suite and observe missing-API RED.
- [x] Implement client and transport APIs, use the existing stdio registry for actual captured-origin eligibility. Validate broker view uniqueness, context, origin range and request headers without resolving pending requests or consuming events.
- [x] Run affected transport suites, verify nonzero GREEN counts. Record evidence. No commit.

## Task 2: Durable response owner and first-dispatch gate

Files: add `ACPV2ResponseOwner.swift`, `ACPV2ResponseAttachment.swift` under AlasSessions/ACP/Session; add `ACPV2ResponseOwnerTests.swift` to package tests.

Interfaces: injectable `ACPV2ResponseLedgerPersisting` using existing intent/attempt/observation signatures; `ACPSessionPersistence` conforms. Concrete `ACPV2ResponseAttachment` accepts actual stdio client or validated broker client/open result, reconciles a retained record and optional original stdio delivery, and hands off existing exact endpoints. Owner initialized with stream/fence/attachment/journal/current predicate. `respond(request:delivery:intentID:attemptID:operationKey:frame:) async throws` returns a durable observation receipt, or a distinct failure. `stop()` invalidates immediately. Reconciliation outcome eligible/unavailable/observationLost.

- [x] Add missing-API RED for a real stdio capture retained in real SQLite: exact chosen bytes are written once only after persisted intent/attempt exist; duplicate calls/history cannot dispatch, unchanged callbacks/ACKs; malformed/foreign origin rejected.
- [x] Implement concrete source matching, persistence protocol, per-origin local operation registry, intent/attempt registration and insert-only first dispatch. Recheck local ownership/cancellation after every await and before exact endpoint entry. No auto retry of an existing attempt.
- [x] Retain typed observation and report durable success only after commit. Separate endpoint errors, persistence errors and invalidation; no synthesized notWritten facts.
- [x] Add recovery regression with actual persistence: new owner cannot hand off unresolved existing attempt; factual stdio notWritten allows explicit new key after reconciliation. Run owner and affected transport suites to GREEN. No commit.

## Task 3: Invalidation, joined callers and end-to-end recovery boundaries

Files: extend new owner suite and existing transport suites; adjust owner implementation as needed.

- [x] Add event-gated RED for intent/attempt/reconciliation/handoff/observation waits, cancellation of initiator vs joiner, stop and ownership replacement. Assert caller settlement before gated work returns, no stale success, no second handoff, and no unrelated operation cancellation.
- [x] Implement per-operation initiator cancellation, independent joined-waiter cancellation, prompt stop settlement, late fact retention only through valid fences, and outcome-persistence failure reporting. Ensure original task cancellation reaches exact endpoint worker while no worker can revive authority.
- [x] Add end-to-end broker same-origin reattachment/removal/reuse and stale snapshot rejection tests, exact UTF-8 source matching, outcome commit failure reopening uncertain, lease seizure blocking late mutation. Avoid overlapping transport-only assertions.
- [x] Run focused package suites with actual test counts, SwiftFormat and whitespace checks. Attempt native focused suites only if affected app-owned tests require it; package-only coverage needs no app build. Record cross-process arbitration limit and all deviations.

## Task 4: One fresh final review and handoff

- [x] Provide approved design, plan, baseline and working diff/new files to one fresh reviewer. Include ledger rulings and review focus. Preserve unrelated files.
- [x] Regrade findings by practical effect. Fix Critical/Important findings in one combined RED/GREEN pass. Record declined judgments and deferred Minors. No rereview.
- [x] Run final affected suites and lint, inspect counts. Update docs/evidence and #2213 if appropriate, report exact limitations. Leave implementation uncommitted.

## Execution evidence and rulings

- Task 1 missing-API RED, then 35 tests/3 suites GREEN. Task 2 missing-owner RED, then 36 tests/3 suites GREEN. Task 3 exposed missing local-session and returned-fact checks; both pinned RED then fixed. Combined affected suites: 74 tests/9 suites passed in `/private/tmp/alas-owner-combined.log`.
- Broker pending refresh uses an explicit attach without applying replay events or flushing ACKs. It adds no consumption authority.
- Prompt blocked-call settlement requires the lifecycle caller to invoke `stop()` on ownership/attachment invalidation. A current-ownership predicate is checked after awaits, not polled while dependencies block.
- A written stdio origin may become unavailable before recovery reaches the existing-attempt gate. Tests assert no handoff rather than demanding one rejection reason.
- Latest-only owner events expose waiting caller counts to observe joins and settlement. Durable facts remain in schema 34.
- This change touches only package code/tests, so package suites cover it without native app test-source copies or an app build. Production, CI and live interoperability remain unverified.

## Final review and verification

One fresh read-only final review found 3 Important findings and 1 Minor. The Important findings were reproduced and fixed in one combined pass, without rereview:

- Initiator cancellation was only published through an actor hop. A regression cancelling inside the ownership predicate reproduced another durable attempt registration after cancellation. The synchronous per-call cancellation latch now withdraws authority before further registration/handoff; joined waiters retain independent cancellation.
- Observation persistence failure discarded the typed returned fact. `Failure.outcomePersistence(attemptID:fact:message:)` now exposes the local normalized source/status fact separately from a durable receipt, including rejected observation proofs. The saved attempt remains uncertain when its outcome cannot be committed.
- Failure before registration permanently cached an unavailable origin. Failed slots can now be explicitly reconciled again only before attempt registration starts. Potentially committed attempts retain the insert-only gate. Missing stdio delivery and transient broker attach failures both have recovery regressions.

Deferred Minor: cancellation while an attempt receipt is blocked after COMMIT may skip its best-effort pre-handoff diagnostic. The unresolved registration remains uncertain and cannot authorize another write; no certainty is invented.

Final affected package selection passed 77 tests in 9 suites, `/private/tmp/alas-owner-final-verified.log`. It includes response owner, raw broker client/helper, raw reply validation, inbound receipt owner/delivery, factual frame writer, negotiation and broker transport. Full SwiftFormat lint passed with 0/2756 files requiring formatting and 1 skipped, `/private/tmp/alas-owner-lint-final.log`. Tracked and new-file whitespace checks passed. No app code/tests changed, so no native app build was run. No CI, live adapter or SSH qualification is claimed.

Accepted review exclusions: production lifecycle installation and callers' delivery of stop notifications, native app/UI, CI/live interoperability, cross-process arbitration/exactly-once execution, semantic decisions/execution, automatic retry/read-only factual lookup, pre-existing store/transport correctness outside this composition, unmeasured resource behavior and unrelated work. Package tests do not qualify any of these.

All implementation remains uncommitted on `nacho/acp-v2-response-owner`; unrelated Ghostty/research remains unchanged. No schema change, consumption callback, ACK authority or production activation was added.
