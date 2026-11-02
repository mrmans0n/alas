# ACP v2 attachment runtime implementation plan

> Execute inline with superpowers:executing-plans. Full design approval authorizes planning and execution without another handoff menu. Leave implementation uncommitted until shipping is requested.

**Goal:** Compose v2 durable update/submission, inbound receipt and response owners with reliable request offers and one attachment lifecycle.

**Architecture:** Add fenced synchronous post-commit callbacks to the inbound owner. A package runtime supplies concrete attachment descriptors and child journals, consumes each assigned stream once, exposes opaque epoch-bound request handles and gates commands on both owners' readiness. Child owners retain their existing authority and persistence rules.

**Tech stack:** Swift, Swift Testing, existing SQLite persistence actor and ACP transports.

**Spec:** `docs/plans/2026-11-02-acp-v2-attachment-runtime-design.md`

## Global constraints

Post-setup opt-in package only; production remains v1-only. No schema, app runner/UI, method execution/decisions, queue advancement or new ACK authority. Preserve exact frame/source identity, copied receipt semantics and uncertain outcomes. Original stdio capture cannot be reconstructed. No fixed sleeps or new test serialization. Preserve unrelated Ghostty/research. One fresh final review and one material fix pass, no rereview. No implementation commits before shipping request.

## Review focus

- Reliable callbacks must not be replaced by latest-only observations. Burst/copy/history tests in Task 1/2.
- A callback can synchronously stop the runtime; recheck before consumption. Task 1/3.
- A request offered before both journals restore must not authorize commands early. Task 2/3.
- Independent broker streams share a protected ACK prefix; neither can consume the other's work. Task 3.
- Child EOF/failure and blocked persistence must withdraw all commands without closing a successor transport. Task 3.

## Task 1: Reliable inbound registration and retention callbacks

Files: `ACPV2InboundReceiptOwner.swift`, existing `ACPV2InboundReceiptOwnerTests.swift`.

Interfaces: optional injected `onStreamRegistered: @MainActor (ACPV2InboundLedgerStream) throws -> Void` and `onRetained: @MainActor (ACPV2InboundDelivery, ACPV2InboundLedgerReceipt) throws -> Void`. Default nil preserves existing callers. Registration follows descriptor validation; retention follows COMMIT, proof/ordinal validation. Both have a subsequent current/stop check; retention precedes consumption. Historical replay never invokes live callbacks.

- [x] Add missing-API RED for reliable original-delivery callback, duplicate live receipt and silent history, checking the actual persisted page and consumption order.
- [x] Add reentrant-stop variants for registration and retention; no callback-derived or successor consumption.
- [x] Implement callbacks without interpreting payloads or changing observation buffering. Run affected inbound owner suite with nonzero GREEN counts. No commit.

## Task 2: Concrete runtime, opaque offers and gated commands

Files: new `ACPV2AttachmentRuntime.swift` in AlasSessions/ACP/Session; new `ACPV2AttachmentRuntimeTests.swift` in package tests.

Interfaces: nested `Attachment` with concrete stdio/broker constructors; nested `Journals` with initializer from `ACPSessionPersistence` and explicit update/inbound/submission/response protocol implementations; `Request` with public retained record and private runtime epoch/original delivery; `Status` idle/restoring/ready/observationLost/blocked/stopped; latest-only `observations`. `start() -> Bool`, `stop()`, canonical `state`, explicit `submit(id:localRowID:params:operationKey:)` and `respond(to:intentID:attemptID:operationKey:frame:)` delegate existing contracts. Runtime init takes sessionId/upstreamSessionId/attachment/fence/journals/isCurrent/onRequest.

- [x] Write missing-runtime RED for real captured stdio burst, every distinct request offered after COMMIT with original delivery, and one exact response through real persistence. Notifications/malformed frames create no offers; history cannot mint handles.
- [x] Implement validated attachment construction, child owner assembly, reliable callback handoff and dedup by stream/ordinal. Subscribe child owners once to their exclusive streams. Keep response owner creation behind validated inbound stream registration.
- [x] Add readiness gating with an update replay gate, early offer retention, submit/acceptance plus running/idle canonical state through the runtime. Acceptance must not invent foreground completion. Use the real client and persistence; fake only transport/await boundaries.
- [x] Implement explicit command forwarding, epoch/handle checks and final current/readiness checks. Run runtime and affected owner suites GREEN. No commit.

## Task 3: Lifecycle races and broker composition

Files: extend new runtime suite; extend existing broker suite using its fixture. Reuse existing journal gates where possible.

- [x] Add RED for blocked retention, registration/proof failure, reentrant request callback stop, EOF on either stream, lease/attachment replacement and foreign/old handles. Check no offers/consumption or stale success after invalidation, and no underlying client shutdown by runtime stop.
- [x] Implement synchronous parent invalidation and child monitoring. Read current child states after stream end; ignore intentional stop. Stop response, inbound and update/submission owners without awaiting blocked work. Preserve current-ownership predicate boundary semantics.
- [x] Add broker integration with actual pending snapshot reattachment and update/request persistence completing in either order; ACK cannot cross the earlier uncommitted receipt. Replay history offers none; current duplicate pending capture offers once and remains answerable through exact origin checks.
- [x] Run focused package runtime/inbound/update/response/broker/negotiation suites. Run SwiftFormat and whitespace checks, inspect counts. No native app build for package-only changes, no CI/live claims. Record every deviation/ruling. No commit.

## Task 4: One fresh final review and handoff

- [x] Provide fixed baseline, working diff/new files, design, plan and ledger to one fresh read-only reviewer. Include the Review focus above. Exclude unrelated files.
- [x] Regrade by effect. Fix Critical/Important in one combined RED/GREEN pass; record deferred Minors and declined judgments. No rereview.
- [x] Verify final affected suites and lint, update evidence/docs/umbrella as appropriate. Report current limits and leave product work uncommitted.

## Execution rulings and pre-review evidence

The stdio facade routes raw RPC diagnostics separately from valid method deliveries. A narrow `ACPV2InboundDelivery(stdioDiagnostic:)` adapter preserves its receipt UUID, bytes, connection and single-use consumption; the runtime fans that stream into retention while excluding it from offers. This is evidence adaptation, never reply capture registration. No cross-stream total order is invented.

Initial callback RED then GREEN10/1, runtime contract RED then GREEN14/2, composition GREEN90/6. Two extra concrete ownership regressions were pinned RED and fixed: source-reader ownership loss left stale ready status; caller cancellation invalidated the whole attachment. Final review input passed111 tests/10 suites in `/private/tmp/alas-runtime-review-input-verified.log`. The command-cancellation edit initially missed the formatted guard; the repeated failure was inspected and corrected before the verified run.

MainActor isolation follows existing child owners and callback APIs. Journals can override one dependency while defaulting all fields to the same persistence actor; this avoids a multi-protocol test fake. Lifecycle callers still deliver explicit stop notifications, while observed loss at source boundaries invalidates all children. Cancelling a command remains caller-local. No native app build or CI/live interoperability result is claimed for this package-only slice.

## Final review and verification

One fresh read-only review found 0 Critical, 1 Important and 0 Minor findings. The Important finding was reproduced with an event-gated high-priority submission released immediately before an inbound proof failed. The old code wrote a97-byte prompt while the terminal sibling's monitor was pending. `/private/tmp/alas-runtime-final-red.log` failed1 test/1 suite with1 issue.

The single fix pass moved terminal-child inspection into the shared synchronous current-authority predicate. It withdraws the whole epoch before any resumed sibling worker or consumption boundary can proceed. A startup flag prevents recursive lazy-child construction; the predicate does not call synchronize(). Monitors remain status observers rather than the only invalidation path. No rereview occurred.

Final selection passed112 tests/10 suites, `/private/tmp/alas-runtime-final-green.log`: runtime, inbound receipt owner, broker client/helper, update/submission owner, response owner, inbound delivery, negotiation, raw reply and raw RPC delivery. Full SwiftFormat lint passed with0/2762 files requiring formatting,1 skipped, `/private/tmp/alas-runtime-final-lint.log`. Tracked/new-file whitespace checks passed. No app code/tests changed, so no native app build was run. CI and live adapter/SSH behavior remain unverified.

No new Minor findings were deferred. Accepted review exclusions: production runner installation/activation/setup/negotiation/native/SSH qualification; semantic method execution/permission/UI/queue/completion presentation; cross-process lease/write atomicity and underlying transport/successor closure contracts; transient response pending-view errors remain command-local rather than terminal ingress loss; throughput/long-session memory/crash interoperability/repository-wide CI unverified; unrelated work excluded. These are not inferred successes.

Implementation remains uncommitted on `nacho/acp-v2-attachment-runtime`. Production remains v1-only; no schema change or new ACK authority was added. Next integration still needs initialization/setup and app-runner installation with explicit decision policies, projection and exact-adapter qualification.
